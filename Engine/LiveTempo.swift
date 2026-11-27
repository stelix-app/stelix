// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Accelerate
import Foundation
import StelixCore

/// The Live tempo and key, while the Live plays and the panel is open. When `LiveAnalysisClock` says so,
/// the input that arrived since the last time is copied from the ring (never in the IOProc, never on the
/// ML thread), mixed to mono and kept for `LiveTempoWindow.seconds`. The tempo, every
/// `LiveTempoWindow.hop` s on all of it, passes through `TempoFollower` and leaves as `.tempo(bpm:)`;
/// the key, on the last `LiveKeyWindow.seconds`, every 2 s while none shows and every 4 s while one does,
/// passes through `KeyFollower` and leaves as `.key`; both only when they change. Both are read around
/// what the user hears (the newest input minus the Live delay), not at the newest input. On silence
/// there is no analysis and tempo and key are `nil`. Half a second of silence (`LivePauseWatch`, the gap
/// between two songs) restarts the key, and its window starts after it. With the panel closed nothing is
/// analyzed; if the music did not pause meanwhile, the key comes back at once on reopening.
///
/// Everything here runs on the Live `control` queue, except the analysis, which comes back to it.
final class LiveTempo: @unchecked Sendable {
    /// At the first tick the window starts with what the ring already holds, up to this:
    /// opening the panel during a song gives a number at once. The ring holds at least 12 s.
    static let initialSeconds = 10.0
    /// The Live tick.
    static let tickSeconds = 0.05

    private let control: DispatchQueue
    private let emit: @Sendable (Event) -> Void

    private var running = false
    /// The panel is closed with the Live playing: the key stays in `keyFollower` for the reopening.
    private var suspended = false
    /// Every tick while the Live plays, panel open or not.
    private var pauseWatch = LivePauseWatch()
    /// `pauseWatch.pauses` when the panel closed.
    private var pausesAtSuspend = 0
    private var clock = LiveAnalysisClock()
    private var pipelineID: ObjectIdentifier?
    private var rate = 0.0
    /// Mono input, the last `LiveTempoWindow.seconds` at `rate`.
    private var history: [Float] = []
    private var copiedUpTo: Int64 = 0
    private var analyzing = false
    private var analysis: Task<Void, Never>?
    /// Discards an analysis that finishes after a stop or a new pipeline.
    private var generation = 0
    /// Discards a key analysis that finishes after a pause restarted the key.
    private var keyGeneration = 0
    private var follower = TempoFollower()
    private var keyFollower = KeyFollower()
    /// What the app was told last; `.none` before anything was said.
    private var sent: Double??
    private var sentKey: MusicalKey??

    init(control: DispatchQueue, emit: @escaping @Sendable (Event) -> Void) {
        self.control = control
        self.emit = emit
    }

    /// From the Live tick (20 Hz). `peak`: of the input since the last tick (0 if the output is not running).
    func tick(pipeline: LivePipeline?, playing: Bool, panelOpen: Bool, peak: Float, now: Double) {
        guard let pipeline, playing else {
            if running || suspended { stop(tellApp: true) }
            return
        }
        let id = ObjectIdentifier(pipeline)
        if (running || suspended) && id != pipelineID { stop(tellApp: false) }
        let pauseBegan = pauseWatch.observe(peak: peak, seconds: Self.tickSeconds)
        guard panelOpen else {
            if running { suspend() }
            return
        }
        if !running || id != pipelineID {
            let resumed = suspended && id == pipelineID && pauseWatch.pauses == pausesAtSuspend ? keyFollower : nil
            let watch = pauseWatch
            stop(tellApp: false)
            pauseWatch = watch
            running = true
            pipelineID = id
            rate = pipeline.timing.deviceRate
            copiedUpTo = max(0, pipeline.ring.writtenFrames - Int64(Self.initialSeconds * rate))
            if var resumed {
                resumed.resume()
                keyFollower = resumed
                if resumed.key != nil { sendKey(resumed.key) }
            }
        }
        if pauseBegan {
            // Another song, most likely: the key starts over (an analysis under way is still on the old one).
            keyFollower.reset()
            sendKey(nil)
            keyGeneration += 1
        }
        guard !analyzing else { return }
        let due = clock.due(at: now, keyShown: keyFollower.key != nil)
        guard due.tempo || due.key else { return }
        guard copyNewInput(from: pipeline.ring) else { return }

        guard let music = LiveTempoWindow.musicSeconds(peaks: blockPeaks()) else {
            follower.reset()
            keyFollower.reset()
            send(nil)
            sendKey(nil)
            return
        }
        analyzing = true
        let delay = pipeline.timing.delaySeconds
        // Read where the user listens, not at the newest input: what is heard is `delay` behind it.
        let tempoSamples = due.tempo ? Array(history.suffix(Int(music * rate))) : []
        let listening = LiveTempoWindow.listeningTime(musicSeconds: music, delaySeconds: delay)
        let keyMusic = due.key ? LiveKeyWindow.music(available: music, sincePause: pauseWatch.musicSincePause) : nil
        let keySamples = keyMusic.map { Array(history.suffix(Int($0 * rate))) } ?? []
        let keyListening = LiveTempoWindow.listeningTime(musicSeconds: keyMusic ?? 0, delaySeconds: delay)
        let rate = rate
        let generation = generation
        let keyGeneration = keyGeneration
        analysis = Task.detached(priority: .utility) { [self] in
            let beats = due.tempo ? await TempoAnalysis.analyze(mono: tempoSamples, rate: rate, key: false).beats : nil
            let keys = keyMusic != nil ? await TempoAnalysis.keys(mono: keySamples, rate: rate) : nil
            control.async { [self] in
                guard generation == self.generation else { return }
                analyzing = false
                if due.tempo { send(follower.observe(beats.flatMap { TempoMap(beats: $0).bpm(at: listening) })) }
                if keyMusic != nil, keyGeneration == self.keyGeneration {
                    sendKey(keyFollower.observe(keys.flatMap { KeyMap(spans: $0).key(at: keyListening) }))
                }
            }
        }
    }

    /// Live stopped or rebuilt: everything starts over. `tellApp` sends `nil` if a number was on screen.
    func stop(tellApp: Bool) {
        if tellApp, case .some(.some) = sent { emit(.tempo(bpm: nil)) }
        if tellApp, case .some(.some) = sentKey { emit(.key(nil)) }
        halt()
        pipelineID = nil
        suspended = false
        pauseWatch = LivePauseWatch()
        follower.reset()
        keyFollower.reset()
    }

    /// The panel closed with the Live playing: no analysis, the app clears what it showed; the key stays
    /// in `keyFollower` and the pipeline in `pipelineID`, to come back if the music does not pause.
    private func suspend() {
        halt()
        suspended = true
        pausesAtSuspend = pauseWatch.pauses
        follower.reset()
    }

    private func halt() {
        generation += 1
        analysis?.cancel()
        analysis = nil
        running = false
        history = []
        copiedUpTo = 0
        analyzing = false
        clock = LiveAnalysisClock()
        sent = .none
        sentKey = .none
    }

    // MARK: - Support

    private func send(_ bpm: Double?) {
        if case .some(let previous) = sent, previous == bpm { return }
        sent = .some(bpm)
        emit(.tempo(bpm: bpm))
    }

    private func sendKey(_ key: MusicalKey?) {
        if case .some(let previous) = sentKey, previous == key { return }
        sentKey = .some(key)
        emit(.key(key))
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
