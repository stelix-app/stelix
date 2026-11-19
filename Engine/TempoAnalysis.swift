// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import MusicUnderstanding
import StelixCore
import Synchronization

/// Beat times with Apple's MusicUnderstanding framework (macOS 27, on the device, no network:
/// piani/ricerca-bpm.md). Before macOS 27 every call gives `nil` and nothing runs; the framework is
/// weak-linked (`project.yml`), so the engine still starts there.
enum TempoAnalysis {
    static var isAvailable: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Beats of a whole file, in seconds, or `nil` (older macOS, file it cannot read, protected
    /// content, cancelled).
    static func beats(ofFile url: URL) async -> [Double]? {
        guard #available(macOS 27, *) else { return nil }
        do {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let session = try await MusicUnderstandingSession(asset: asset)
            return try await analyze(session)
        } catch {
            engineLog("tempo: file analysis failed (\(LogPrivacy.describe(error: error)))")
            return nil
        }
    }

    /// Beats of mono samples at `rate`, in seconds from the first sample, or `nil`.
    static func beats(mono samples: [Float], rate: Double) async -> [Double]? {
        guard #available(macOS 27, *), !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        let chunk = 8192
        var buffers: [AVReadOnlyAudioPCMBuffer] = []
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            buffers.append(AVReadOnlyAudioPCMBuffer(copying: buffer))
            start += count
        }
        let stream = AsyncStream<AVReadOnlyAudioPCMBuffer> { continuation in
            for buffer in buffers { continuation.yield(buffer) }
            continuation.finish()
        }
        do {
            return try await analyze(MusicUnderstandingSession(audioProvider: stream))
        } catch {
            engineLog("tempo: window analysis failed (\(error))")
            return nil
        }
    }

    /// Rhythm only (the other analyses cost more), cancelled with the calling task.
    @available(macOS 27, *)
    private static func analyze(_ session: MusicUnderstandingSession) async throws -> [Double]? {
        try await withTaskCancellationHandler {
            let rhythm = try await session.analyze(for: [.rhythm]).rhythm
            return rhythm?.beats.map(\.seconds).filter(\.isFinite)
        } onCancel: {
            Task { await session.cancel() }
        }
    }
}

/// The beats of a Studio job's source track, analyzed alongside the separation (a few seconds
/// against tens). `wait` blocks the calling queue, never the main one.
final class FileTempo: Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let value = Mutex<[Double]?>(nil)
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(url: URL) {
        guard TempoAnalysis.isAvailable else {
            done.signal()
            return
        }
        let began = Date()
        let started = Task.detached(priority: .utility) { [self] in
            let beats = await TempoAnalysis.beats(ofFile: url)
            value.withLock { $0 = beats }
            engineLog(String(format: "tempo: %d beats in %.1f s", beats?.count ?? 0, Date().timeIntervalSince(began)))
            done.signal()
        }
        task.withLock { $0 = started }
    }

    /// The beats, when the analysis ends; `nil` if it failed.
    func wait() -> [Double]? {
        done.wait()
        done.signal()   // a second call does not block
        return value.withLock { $0 }
    }

    /// Also frees a `wait` in progress, which returns what there is (usually `nil`): an engine that exits
    /// must not wait for the analysis beyond the grace before SIGKILL.
    func cancel() {
        task.withLock { $0?.cancel() }
        done.signal()
    }

    /// After Cancel the beats still count if they arrive within this; then the stems go without them,
    /// before the app stops waiting for the answer to the cancellation (`StudioViewModel.cancelTimeout`, 5 s).
    static let cancelGrace: DispatchTimeInterval = .seconds(3)

    func cancel(after delay: DispatchTimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in cancel() }
    }
}
