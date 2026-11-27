// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import StelixCore
import Synchronization

/// The Studio key over the clip (`KeyScan`), in the background: it starts with the separation and the
/// stems never wait for it (Gabriele, 26/11). One window at a time at low priority, the one nearest to
/// where the user listens first. Its windows reach the app only once the stems are there (`deliver`),
/// then at most twice a second and at the end.
final class KeyScanner: Sendable {
    let path: String
    let folder: String
    private let emit: @Sendable (Event) -> Void
    /// Where the player is, seconds: the windows there come first.
    private let position: @Sendable () -> Double
    private let state: Mutex<State>
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let trackTask = Mutex<Task<Void, Never>?>(nil)

    private struct State {
        var scan: KeyScan?
        var delivered: Bool
        var lastEmit = -Double.infinity
    }

    static let emitInterval = 0.5

    init(path: String, folder: String, done: KeyScan?, delivered: Bool,
         emit: @escaping @Sendable (Event) -> Void, position: @escaping @Sendable () -> Double) {
        self.path = path
        self.folder = folder
        self.emit = emit
        self.position = position
        state = Mutex(State(scan: done, delivered: delivered))
    }

    func start() {
        guard TempoAnalysis.isAvailable else { return }
        let started = Task.detached(priority: .utility) { [self] in await run() }
        task.withLock { $0 = started }
    }

    /// The stems of `folder` are in the app: from now on the windows go to it, starting with those found so far.
    func deliver() {
        let scan = state.withLock { state -> KeyScan? in
            state.delivered = true
            state.lastEmit = Self.now()
            return state.scan
        }
        if let scan { emit(.keyScan(folder: folder, scan)) }
    }

    var isDelivered: Bool { state.withLock { $0.delivered } }

    func cancel() {
        task.withLock { $0?.cancel() }
        trackTask.withLock { $0?.cancel() }
    }

    private func run() async {
        let url = URL(fileURLWithPath: path)
        let began = Date()
        guard let duration = state.withLock({ $0.scan?.duration }) ?? Self.duration(of: url) else {
            engineLog("keys: the source cannot be read")
            return
        }
        let trackChecked = state.withLock { state -> Bool in
            if state.scan == nil { state.scan = KeyScan(duration: duration) }
            return state.scan?.trackChecked ?? false
        }
        // The key of the whole track, alongside the windows: the fallback where they wander.
        if !trackChecked {
            let started = Task.detached(priority: .utility) { [self] in
                let began = Date()
                let key = await TempoAnalysis.trackKey(file: url)
                guard !Task.isCancelled else { return }
                engineLog(String(format: "keys: track key in %.1f s", Date().timeIntervalSince(began)))
                setTrackKey(key)
            }
            trackTask.withLock { $0 = started }
        }
        await withTaskGroup(of: (Int, KeyWindow?).self) { group in
            // Being analyzed, or failed: a window that cannot be read or analyzed stays missing (unsure).
            var busy = Set<Int>()
            func startNext() -> Bool {
                let near = position()
                guard let index = state.withLock({ $0.scan?.next(around: near, excluding: busy) }) else { return false }
                busy.insert(index)
                group.addTask { (index, await Self.analyze(url: url, window: index)) }
                return true
            }
            for _ in 0..<KeyScan.concurrent where startNext() {}
            while let (index, finished) = await group.next() {
                guard !Task.isCancelled else { break }
                if let finished {
                    busy.remove(index)
                    add(finished)
                }
                _ = startNext()
            }
            group.cancelAll()
        }
        guard !Task.isCancelled else { return }
        let count = state.withLock { $0.scan?.windows.count ?? 0 }
        engineLog(String(format: "keys: %d windows in %.1f s", count, Date().timeIntervalSince(began)))
        flush()
    }

    private func add(_ window: KeyWindow) {
        let send = state.withLock { state -> KeyScan? in
            state.scan?.add(window)
            let now = Self.now()
            guard state.delivered, let scan = state.scan,
                  scan.isComplete || now - state.lastEmit >= Self.emitInterval else { return nil }
            state.lastEmit = now
            return scan
        }
        if let send { emit(.keyScan(folder: folder, send)) }
    }

    private func setTrackKey(_ key: MusicalKey?) {
        let send = state.withLock { state -> KeyScan? in
            state.scan?.setTrackKey(key)
            guard state.delivered else { return nil }
            state.lastEmit = Self.now()
            return state.scan
        }
        if let send { emit(.keyScan(folder: folder, send)) }
    }

    /// The last windows, if the interval held them back.
    private func flush() {
        let scan = state.withLock { state -> KeyScan? in state.delivered ? state.scan : nil }
        if let scan { emit(.keyScan(folder: folder, scan)) }
    }

    /// One window, mixed to mono at the file's rate; `nil` (not counted) if it cannot be read or the task
    /// was cancelled, a window with `nil` key if the analysis found none.
    private static func analyze(url: URL, window index: Int) async -> KeyWindow? {
        guard let (samples, rate) = monoWindow(url: url, start: Double(index) * KeyScan.hop, seconds: KeyScan.seconds)
        else { return nil }
        let key = await TempoAnalysis.key(mono: samples, rate: rate)
        guard !Task.isCancelled else { return nil }
        return KeyWindow(index: index, key: key)
    }

    private static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// `seconds` from `start`, the channels averaged. Each window opens its own file.
    private static func monoWindow(url: URL, start: Double, seconds: Double) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let from = AVAudioFramePosition(start * rate)
        guard from < file.length else { return nil }
        let count = AVAudioFrameCount(min(seconds * rate, Double(file.length - from)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let channels = buffer.floatChannelData else { return nil }
        file.framePosition = from
        do { try file.read(into: buffer, frameCount: count) } catch { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channelCount)
        for channel in 0..<channelCount {
            let source = channels[channel]
            for frame in 0..<frames { mono[frame] += source[frame] * scale }
        }
        return (mono, rate)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// The one `KeyScanner` of the engine, for the clip the Studio is on. A job on the same source (Change
/// Model) keeps it; another source replaces it.
final class KeyScans: Sendable {
    private let current = Mutex<KeyScanner?>(nil)
    private let emit: @Sendable (Event) -> Void
    private let position: @Sendable () -> Double

    init(emit: @escaping @Sendable (Event) -> Void, position: @escaping @Sendable () -> Double) {
        self.emit = emit
        self.position = position
    }

    /// A separation of `path` into `folder` has started: the scan starts with it.
    func jobStarted(path: String, folder: String) {
        replace(path: path, folder: folder, done: nil, delivered: false)
    }

    /// The stems of `folder` reached the app: their key follows.
    func stemsReady(folder: String) {
        guard let scanner = current.withLock({ $0 }), scanner.folder == folder else { return }
        scanner.deliver()
    }

    /// The separation of `path` failed or was cancelled: a scan whose stems never arrived stops.
    func jobEnded(path: String) {
        let stopped = current.withLock { scanner -> KeyScanner? in
            guard let found = scanner, found.path == path, !found.isDelivered else { return nil }
            scanner = nil
            return found
        }
        stopped?.cancel()
    }

    /// A new engine with stems already in the app (`.scanKeys`): the windows still missing.
    func resume(path: String, folder: String, done: KeyScan?) {
        replace(path: path, folder: folder, done: done, delivered: true)
    }

    func stop() {
        current.withLock { scanner -> KeyScanner? in
            defer { scanner = nil }
            return scanner
        }?.cancel()
    }

    private func replace(path: String, folder: String, done: KeyScan?, delivered: Bool) {
        let (old, new) = current.withLock { scanner -> (KeyScanner?, KeyScanner?) in
            if let same = scanner, same.path == path, same.folder == folder { return (nil, nil) }
            let old = scanner
            scanner = KeyScanner(path: path, folder: folder, done: done, delivered: delivered,
                                 emit: emit, position: position)
            return (old, scanner)
        }
        old?.cancel()
        new?.start()
    }
}
