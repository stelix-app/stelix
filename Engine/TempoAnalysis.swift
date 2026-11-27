// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import MusicUnderstanding
import StelixCore
import Synchronization

/// Beat times and keys with Apple's MusicUnderstanding framework (macOS 27, on the device, no network:
/// piani/ricerca-bpm.md). Before macOS 27 every call gives nothing and nothing runs; the framework is
/// weak-linked (`project.yml`), so the engine still starts there.
enum TempoAnalysis {
    static var isAvailable: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Beats of a whole file; `nil` on an older macOS, a file it cannot read, protected content, a
    /// cancellation. No key: on a whole file Apple gives one for the track; the Studio's comes from
    /// `KeyScanner`'s windows.
    static func analyze(file url: URL) async -> MusicAnalysis {
        guard #available(macOS 27, *) else { return MusicAnalysis() }
        do {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let session = try await MusicUnderstandingSession(asset: asset)
            return try await analyze(session, key: false)
        } catch {
            engineLog("tempo: file analysis failed (\(LogPrivacy.describe(error: error)))")
            return MusicAnalysis()
        }
    }

    /// The key Apple gives for a whole file (one for the track, measured on 26/11), the longest range's;
    /// `nil` if none, on an older macOS, or for a file it cannot read. The Studio's fallback (`KeyScan`).
    static func trackKey(file url: URL) async -> MusicalKey? {
        guard #available(macOS 27, *) else { return nil }
        do {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let session = try await MusicUnderstandingSession(asset: asset)
            let spans = try await analyzeKey(session).keys ?? []
            return spans.max { $0.end - $0.start < $1.end - $1.start }?.key
        } catch {
            engineLog("keys: track analysis failed (\(LogPrivacy.describe(error: error)))")
            return nil
        }
    }

    /// Beats (and the keys, with `key`) of mono samples at `rate`, in seconds from the first sample.
    static func analyze(mono samples: [Float], rate: Double, key: Bool) async -> MusicAnalysis {
        await analyze(mono: samples, rate: rate, types: key ? .rhythmAndKey : .rhythm)
    }

    /// The key alone of mono samples (a Studio window): the one of the longest range, `nil` if none.
    /// Measured on 26/11: 0.21 s for 20 s, against 0.39 s with the rhythm.
    static func key(mono samples: [Float], rate: Double) async -> MusicalKey? {
        let spans = await analyze(mono: samples, rate: rate, types: .key).keys ?? []
        return spans.max { $0.end - $0.start < $1.end - $1.start }?.key
    }

    /// The key ranges alone of mono samples (the Live key window).
    static func keys(mono samples: [Float], rate: Double) async -> [KeySpan]? {
        await analyze(mono: samples, rate: rate, types: .key).keys
    }

    private enum Types { case rhythm, rhythmAndKey, key }

    private static func analyze(mono samples: [Float], rate: Double, types: Types) async -> MusicAnalysis {
        guard #available(macOS 27, *), !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return MusicAnalysis() }
        let chunk = 8192
        var buffers: [AVReadOnlyAudioPCMBuffer] = []
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return MusicAnalysis() }
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
            let session = try MusicUnderstandingSession(audioProvider: stream)
            switch types {
            case .rhythm: return try await analyze(session, key: false)
            case .rhythmAndKey: return try await analyze(session, key: true)
            case .key: return try await analyzeKey(session)
            }
        } catch {
            engineLog("tempo: window analysis failed (\(error))")
            return MusicAnalysis()
        }
    }

    /// Rhythm, and the key with `key`. Measured on 26/11 (M3 Max): the key adds about 20% on a
    /// 3-minute file and 40% on a 20 s window. Cancelled with the calling task.
    @available(macOS 27, *)
    private static func analyze(_ session: MusicUnderstandingSession, key: Bool) async throws -> MusicAnalysis {
        try await withTaskCancellationHandler {
            let result = try await session.analyze(for: key ? [.rhythm, .key] : [.rhythm])
            let beats = result.rhythm?.beats.map(\.seconds).filter(\.isFinite)
            let spans = result.key.map { $0.ranges.compactMap(KeySpan.init(apple:)) }
            return MusicAnalysis(beats: beats, keys: spans?.isEmpty == false ? spans : nil)
        } onCancel: {
            Task { await session.cancel() }
        }
    }
}

extension TempoAnalysis {
    @available(macOS 27, *)
    fileprivate static func analyzeKey(_ session: MusicUnderstandingSession) async throws -> MusicAnalysis {
        try await withTaskCancellationHandler {
            let result = try await session.analyze(for: [.key])
            let spans = result.key.map { $0.ranges.compactMap(KeySpan.init(apple:)) }
            return MusicAnalysis(beats: nil, keys: spans?.isEmpty == false ? spans : nil)
        } onCancel: {
            Task { await session.cancel() }
        }
    }
}

/// What one analysis found; `nil` where it found nothing.
struct MusicAnalysis: Sendable {
    var beats: [Double]?
    var keys: [KeySpan]?
}

@available(macOS 27, *)
extension KeySpan {
    /// Apple's range in seconds and its key as a pitch class; `nil` for a range that is not finite or empty.
    init?(apple ranged: MusicUnderstandingSession.RangedValue<KeyResult.KeySignature>) {
        let start = ranged.range.start.seconds
        let end = ranged.range.end.seconds
        guard start.isFinite, end.isFinite, end > start else { return nil }
        let mode: MusicalKey.Mode = ranged.value.mode == .minor ? .minor : .major
        self.init(start: start, end: end, key: MusicalKey(pitchClass: Self.pitchClass(ranged.value.tonic), mode: mode))
    }

    private static func pitchClass(_ tonic: KeyResult.Tonic) -> Int {
        switch tonic {
        case .c: 0
        case .cSharp, .dFlat: 1
        case .d: 2
        case .dSharp, .eFlat: 3
        case .e: 4
        case .f: 5
        case .fSharp, .gFlat: 6
        case .g: 7
        case .gSharp, .aFlat: 8
        case .a: 9
        case .aSharp, .bFlat: 10
        case .b: 11
        }
    }
}

/// The beats and keys of a Studio job's source track, analyzed alongside the separation (a few seconds
/// against tens). `wait` blocks the calling queue, never the main one.
final class FileTempo: Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let value = Mutex(MusicAnalysis())
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(url: URL) {
        guard TempoAnalysis.isAvailable else {
            done.signal()
            return
        }
        let began = Date()
        let started = Task.detached(priority: .utility) { [self] in
            let analysis = await TempoAnalysis.analyze(file: url)
            value.withLock { $0 = analysis }
            engineLog(String(format: "tempo: %d beats, %d key ranges in %.1f s", analysis.beats?.count ?? 0,
                             analysis.keys?.count ?? 0, Date().timeIntervalSince(began)))
            done.signal()
        }
        task.withLock { $0 = started }
    }

    /// Beats and keys, when the analysis ends; `nil` where it failed.
    func wait() -> MusicAnalysis {
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
