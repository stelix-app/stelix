// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Accelerate
import Foundation
import StelixCore

/// The Live tempo: every `LiveTempoWindow.hop` s, while the Live plays and the panel is open, the
/// input that arrived since the last time is copied from the ring (never in the IOProc, never on the ML
/// thread), mixed to mono and kept for `LiveTempoWindow.seconds`; the music part of it goes to
/// `TempoAnalysis` on a low-priority task. The result passes through `TempoFollower` and leaves as
/// `.tempo(bpm:)`, only when it changes. The tempo is the one around what the user hears (the newest
/// input minus the Live delay), not the one of the newest input. On silence there is no analysis and the tempo is `nil`.
///
/// Everything here runs on the Live `control` queue, except the analysis, which comes back to it.
final class LiveTempo: @unchecked Sendable {
    /// At the first tick the window starts with what the ring already holds, up to this:
    /// opening the panel during a song gives a number at once. The ring holds at least 12 s.
    static let initialSeconds = 10.0

    private let control: DispatchQueue
    private let emit: @Sendable (Event) -> Void

    private var running = false
    private var pipelineID: ObjectIdentifier?
    private var rate = 0.0
    /// Mono input, the last `LiveTempoWindow.seconds` at `rate`.
    private var history: [Float] = []
    private var copiedUpTo: Int64 = 0
    private var lastRun = -Double.infinity
    private var analyzing = false
    private var analysis: Task<Void, Never>?
    /// Discards an analysis that finishes after a stop or a new pipeline.
    private var generation = 0
    private var follower = TempoFollower()
    /// What the app was told last; `.none` before anything was said.
    private var sent: Double??

    init(control: DispatchQueue, emit: @escaping @Sendable (Event) -> Void) {
        self.control = control
        self.emit = emit
    }

    /// From the Live tick (20 Hz). `active`: the Live plays and the panel is open.
    func tick(pipeline: LivePipeline?, active: Bool, now: Double) {
        guard active, let pipeline else {
            if running { stop(tellApp: true) }
            return
        }
        let id = ObjectIdentifier(pipeline)
        if !running || id != pipelineID {
            stop(tellApp: false)
            running = true
            pipelineID = id
            rate = pipeline.timing.deviceRate
            copiedUpTo = max(0, pipeline.ring.writtenFrames - Int64(Self.initialSeconds * rate))
        }
        guard !analyzing, now - lastRun >= LiveTempoWindow.hop else { return }
        lastRun = now
        guard copyNewInput(from: pipeline.ring) else { return }

        guard let music = LiveTempoWindow.musicSeconds(peaks: blockPeaks()) else {
            follower.reset()
            send(nil)
            return
        }
        analyzing = true
        let samples = Array(history.suffix(Int(music * rate)))
        // Read where the user listens, not at the newest input: what is heard is `delay` behind it.
        let listening = LiveTempoWindow.listeningTime(musicSeconds: music,
                                                      delaySeconds: pipeline.timing.delaySeconds)
        let rate = rate
        let generation = generation
        analysis = Task.detached(priority: .utility) { [self] in
            let beats = await TempoAnalysis.beats(mono: samples, rate: rate)
            control.async { [self] in
                guard generation == self.generation else { return }
                analyzing = false
                let estimate = beats.flatMap { TempoMap(beats: $0).bpm(at: listening) }
                send(follower.observe(estimate))
            }
        }
    }

    /// Live stopped, rebuilt or panel closed: everything starts over. `tellApp` sends `nil` if a
    /// number was on screen.
    func stop(tellApp: Bool) {
        generation += 1
        analysis?.cancel()
        analysis = nil
        if tellApp, case .some(.some) = sent { emit(.tempo(bpm: nil)) }
        running = false
        pipelineID = nil
        history = []
        copiedUpTo = 0
        lastRun = -.infinity
        analyzing = false
        follower.reset()
        sent = .none
    }

    // MARK: - Support

    private func send(_ bpm: Double?) {
        if case .some(let previous) = sent, previous == bpm { return }
        sent = .some(bpm)
        emit(.tempo(bpm: bpm))
    }

    /// Appends the frames written since the last copy. `false` if they could not be read (too many,
    /// or overwritten meanwhile): the window starts over from now.
    private func copyNewInput(from ring: SPSCRingBuffer) -> Bool {
        let written = ring.writtenFrames
        var start = copiedUpTo
        let limit = Int64(Self.initialSeconds * rate)
        if written - start > limit {
            // A gap (the queue was busy, the Mac slept): what is older than the window is lost anyway.
            history = []
            start = written - limit
        }
        let frames = Int(written - start)
        guard frames > 0 else { return true }
        let channels = ring.channels
        var interleaved = [Float](repeating: 0, count: frames * channels)
        let ok = interleaved.withUnsafeMutableBufferPointer { ring.copy(from: start, frames: frames, into: $0.baseAddress!) }
        copiedUpTo = written
        guard ok else {
            history = []
            return false
        }
        var mono = [Float](repeating: 0, count: frames)
        interleaved.withUnsafeBufferPointer { source in
            mono.withUnsafeMutableBufferPointer { target in
                for channel in 0..<channels {
                    vDSP_vadd(source.baseAddress! + channel, vDSP_Stride(channels), target.baseAddress!, 1,
                              target.baseAddress!, 1, vDSP_Length(frames))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(target.baseAddress!, 1, &scale, target.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        history.append(contentsOf: mono)
        let keep = Int(LiveTempoWindow.seconds * rate)
        if history.count > keep { history.removeFirst(history.count - keep) }
        return true
    }

    /// The peak of each block of the window, aligned to its end (the last block is whole).
    private func blockPeaks() -> [Float] {
        let block = max(1, Int(LiveTempoWindow.blockSeconds * rate))
        let count = history.count / block
        let offset = history.count - count * block
        return history.withUnsafeBufferPointer { samples in
            (0..<count).map { index in
                var peak: Float = 0
                vDSP_maxmgv(samples.baseAddress! + offset + index * block, 1, &peak, vDSP_Length(block))
                return peak
            }
        }
    }
}
