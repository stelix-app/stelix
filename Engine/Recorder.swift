// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import StelixCore

/// Records the Mac's audio for the Studio into `<temporary folder>/recording.wav`, until
/// `stop()` arrives or for at most `AudioFileLoader.defaultMaxSeconds`.
///
/// The tap is `.unmuted` (you keep hearing) and the IOProc has no output: it only writes to the ring.
/// A timer on the recorder queue, every 50 ms, flushes the ring into the WAV (Float32 stereo at the
/// device rate, channels 1 and 2 of the tap), runs the `SilenceWatchdog` and sends progress at
/// 10 Hz, with the peaks of the 50 ms blocks for the live waveform. On Stop or at the cap: stop and
/// destroy of the tap, closing the file, `.recorded(path:)`.
///
/// If the output changes while recording, the tap is recreated on the new device and writes into the same
/// ring: the WAV keeps a gap of a few hundred ms. If the rate changes, the recording
/// closes there and keeps what is there (a WAV has only one rate).
final class Recorder: @unchecked Sendable {
    static let fileName = "recording.wav"

    private let queue = DispatchQueue(label: "io.github.stelix-app.stelix.engine.recorder", qos: .userInitiated)
    private let emit: @Sendable (Event) -> Void
    private let scratch: StudioScratch
    private var session: Session?
    /// The last finished recording not yet handed to a separation. A `.cancelJob` arriving
    /// right after the end (the app had already pressed Cancel) deletes it: nobody will separate it.
    private var unclaimed: URL?

    init(scratch: StudioScratch, emit: @escaping @Sendable (Event) -> Void) {
        self.scratch = scratch
        self.emit = emit
    }

    func start() {
        queue.async { [self] in
            guard session == nil else {
                emit(.failure(EngineFailure(.alreadyRecording)))
                return
            }
            do throws(EngineFailure) {
                unclaimed = nil
                session = try Session(maxSeconds: AudioFileLoader.defaultMaxSeconds, folders: scratch, queue: queue, emit: emit) { [weak self] recorded in
                    self?.session = nil
                    self?.unclaimed = recorded
                }
            } catch {
                emit(.failure(error))
            }
        }
    }

    /// A recording is in progress. From the engine's command queue, never from the recorder queue.
    var isRecording: Bool { queue.sync { session != nil } }

    /// `.stopRecording`: what is there is kept. Without a recording in progress it does nothing.
    func stop() {
        queue.async { [self] in session?.finish() }
    }

    /// `.cancelJob` during a recording: it stops and the folder is deleted, which contains
    /// only the half-written WAV.
    func cancel() {
        queue.async { [self] in
            guard let session else {
                if let unclaimed {
                    engineLog("rec: cancelled after the recording finished, WAV dropped")
                    try? FileManager.default.removeItem(at: unclaimed.deletingLastPathComponent())
                    self.unclaimed = nil
                }
                return
            }
            session.abort(deleteFolder: true)
            self.session = nil
            emit(.failure(EngineFailure(.recordingCancelled)))
        }
    }

    /// `.separateFile` on `path`: if it is the last recording, from here it belongs to the separator.
    func claim(_ path: String) {
        queue.async { [self] in
            if unclaimed?.path == path { unclaimed = nil }
        }
    }

    /// Engine exit: the tap is destroyed before the process ends.
    func stopAndWait() {
        queue.sync {
            session?.abort(deleteFolder: true)
            session = nil
        }
    }
}

/// A recording in progress. Lives on the recorder queue.
private final class Session: @unchecked Sendable {
    private var tap: SystemTap
    private var watcher: DeviceWatcher?
    private let queue: DispatchQueue
    private let ring: SPSCRingBuffer
    private let file: AVAudioFile
    private let folder: URL
    private let url: URL
    private let targetFrames: Int64
    private let rate: Double
    private let emit: @Sendable (Event) -> Void
    /// The WAV if the recording ended well, otherwise `nil`.
    private let finished: (URL?) -> Void
    private var timer: DispatchSourceTimer?
    private var watchdog: SilenceWatchdog
    private var readFrame: Int64 = 0
    private var peaks: BlockPeaks
    /// The peaks of the blocks closed since the last `.recording`.
    private var pendingPeaks: [Float] = []
    private var done = false
    private var lastProgressAt = Date.distantPast
    private var stall = CallbackStall()
    private var scratch: [Float]
    private let chunkFrames: Int
    private let buffer: AVAudioPCMBuffer

    init(maxSeconds: Double, folders: StudioScratch, queue: DispatchQueue, emit: @escaping @Sendable (Event) -> Void,
         finished: @escaping (URL?) -> Void) throws(EngineFailure) {
        self.emit = emit
        self.finished = finished
        self.queue = queue
        let tap = try SystemTap(mute: .unmuted)
        self.tap = tap
        rate = tap.format.sampleRate
        targetFrames = Int64((maxSeconds * rate).rounded())
        peaks = BlockPeaks(blockFrames: Int((rate * 0.05).rounded()))
        // 8 s of ring: the timer flushes every 50 ms, there is margin even for a slow disk.
        ring = SPSCRingBuffer(channels: tap.format.inputChannels, capacityFrames: Int(rate * 8))
        watchdog = SilenceWatchdog(sampleRate: rate)
        chunkFrames = Int(rate / 4)
        scratch = [Float](repeating: 0, count: chunkFrames * tap.format.inputChannels)

        do throws(EngineFailure) {
            folder = try folders.newFolder()
        } catch {
            tap.destroy()
            throw error
        }
        url = folder.appending(path: Recorder.fileName)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)),
              let file = try? AVAudioFile(forWriting: url, settings: [
                  AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                  AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                  AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
              ], commonFormat: .pcmFormatFloat32, interleaved: false)
        else {
            tap.destroy()
            try? FileManager.default.removeItem(at: folder)
            throw EngineFailure(.recordingUnwritable)
        }
        self.file = file
        self.buffer = buffer

        do throws(EngineFailure) {
            try Self.start(tap, into: ring)
        } catch {
            tap.destroy()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let f = tap.format
        engineLog("rec: \(LogPrivacy.mark(tap.outputName)) \(Int(f.sampleRate)) Hz, \(tap.routeDescription), at most \(Int(maxSeconds)) s")
        emit(.recording(seconds: 0, peaks: []))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
        watcher = DeviceWatcher { [weak self] in
            guard let self else { return }
            queue.async { self.outputChanged() }
        }
    }

    private static func start(_ tap: SystemTap, into ring: SPSCRingBuffer) throws(EngineFailure) {
        try tap.start(output: false) { input, _, frames in
            ring.write(input, frames: frames)
        }
    }

    /// Output changed: write what is there, then a new tap on the same ring. The old one is
    /// destroyed first, so the ring always has a single producer.
    private func outputChanged() {
        guard !done, tap.signature != SystemTap.OutputSignature.current() else { return }
        drain()
        guard !done else { return }
        tap.destroy()
        let next: SystemTap
        do throws(EngineFailure) {
            next = try SystemTap(mute: .unmuted)
        } catch {
            endAfterOutputChange(error)
            return
        }
        guard next.format.sampleRate == rate else {
            next.destroy()
            engineLog("rec: rate changed (\(Int(rate)) → \(Int(next.format.sampleRate)) Hz), stopping here")
            endAfterOutputChange(EngineFailure(.noAudio))
            return
        }
        do throws(EngineFailure) {
            try Self.start(next, into: ring)
        } catch {
            next.destroy()
            endAfterOutputChange(error)
            return
        }
        tap = next
        stall.restart(written: ring.writtenFrames)
        engineLog("rec: output changed, now \(LogPrivacy.mark(next.outputName)), \(next.routeDescription)")
    }

    /// After an output change it cannot continue: keep what is already recorded,
    /// as on Stop; with nothing, the error.
    private func endAfterOutputChange(_ failure: EngineFailure) {
        if readFrame > 0 {
            complete()
        } else {
            fail(failure)
        }
    }

    private func drain() {
        guard !done else { return }
        let written = ring.writtenFrames
        // No callback at start (6 s) or frames stopped afterwards (2 s: device unplugged, AirPods switched off):
        // without this the recording would never end.
        // With the Mac silent the tap does not call the callback: wait, until the output does IO.
        if stall.observe(now: Double(DispatchTime.now().uptimeNanoseconds) / 1e9, written: written,
                         outputRunning: CoreAudioProperty.isRunningSomewhere(tap.signature.device)) {
            fail(EngineFailure(.noAudio))
            return
        }
        if written == 0 { return }
        let available = min(written, targetFrames)
        let channels = ring.channels
        while readFrame < available {
            let n = Int(min(Int64(chunkFrames), available - readFrame))
            let start = readFrame
            let copied = scratch.withUnsafeMutableBufferPointer { ring.copy(from: start, frames: n, into: $0.baseAddress!) }
            guard copied else {
                fail(EngineFailure(.recordingInterrupted))
                return
            }
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            var allZero = true
            for i in 0..<n {
                let l = scratch[i * channels]
                let r = channels > 1 ? scratch[i * channels + 1] : l
                left[i] = l
                right[i] = r
                if l != 0 || r != 0 { allZero = false }
                if let peak = peaks.add(max(abs(l), abs(r))) { pendingPeaks.append(min(peak, 1)) }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            do {
                try file.write(from: buffer)
            } catch {
                fail(EngineFailure(.recordingUnwritable))
                return
            }
            if watchdog.observe(atFrame: readFrame, frames: n, allZero: allZero) == .permissionSuspected {
                engineLog("rec: only zeros since the start, suspected permission")
                emit(.permissionSuspected)
            }
            readFrame += Int64(n)
        }

        if readFrame >= targetFrames {
            complete()
        } else if Date().timeIntervalSince(lastProgressAt) >= 0.095 {
            // 10 Hz: the timer runs at 20 Hz, one tick is sent and one is skipped (the 5% absorbs jitter).
            lastProgressAt = Date()
            sendProgress()
        }
    }

    /// Stop: what is already in the ring is written and closed. If nothing has arrived (with the Mac
    /// silent the tap does not call the callback) it is said, and Retry records again.
    func finish() {
        drain()
        guard !done else { return }
        if readFrame == 0 {
            engineLog("rec: stop without audio")
            abort(deleteFolder: true)
            emit(.failure(EngineFailure(.silentRecording)))
            finished(nil)
            return
        }
        complete()
    }

    private func complete() {
        done = true
        stopTap()
        // The WAV must be closed (header with the right length) before saying it exists.
        file.close()
        let duration = Double(readFrame) / rate
        engineLog(String(format: "rec: done, %lld frames (%.3f s)", readFrame, duration))
        sendProgress()
        emit(.recorded(path: url.path))
        finished(url)
    }

    private func sendProgress() {
        emit(.recording(seconds: Double(readFrame) / rate, peaks: pendingPeaks))
        pendingPeaks = []
    }

    private func stopTap() {
        timer?.cancel()
        timer = nil
        watcher?.invalidate()
        watcher = nil
        tap.destroy()
    }

    private func fail(_ failure: EngineFailure) {
        engineLog("rec: \(failure.code)")
        abort(deleteFolder: true)
        emit(.failure(failure))
        finished(nil)
    }

    func abort(deleteFolder: Bool) {
        done = true
        stopTap()
        if deleteFolder { try? FileManager.default.removeItem(at: folder) }
    }
}
