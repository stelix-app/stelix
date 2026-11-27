// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization

/// A fake engine that emits realistic events, for snapshots and for developing views
/// without real audio. It launches no processes.
public final class DemoEngine: EngineConnection {
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let driver = Mutex<Task<Void, Never>?>(nil)
    private let finished = Mutex(false)
    private let stopRecording = Mutex(false)
    /// The scenario in progress, to answer `cancelJob` like the real engine.
    private let running = Mutex<Running?>(nil)
    private enum Running { case recording, separation }
    /// The Studio player, faked like `StudioPlayer`: a tick every `statsInterval / 5` (50 ms by default)
    /// with the levels (telemetry on) and, every other tick, the position.
    private let playback = Mutex(Playback())
    private struct Playback {
        var task: Task<Void, Never>?
        var position: Double = 0
        var duration: Double = 10
        var telemetry = false
    }
    private let fillDuration: Duration
    private let statsInterval: Duration

    /// - Parameters:
    ///   - fillDuration: how long the buffer fill lasts in Live.
    ///   - statsInterval: how often `liveStats` and `levels` come out (4 Hz by default).
    public init(fillDuration: Duration = .seconds(1), statsInterval: Duration = .milliseconds(250)) {
        self.fillDuration = fillDuration
        self.statsInterval = statsInterval
        (events, continuation) = AsyncStream.makeStream()
    }

    public func start() async throws {
        try await Task.sleep(for: .milliseconds(100))
        continuation.yield(.ready)
    }

    public func send(_ command: Command) {
        switch command {
        case .startLive:
            drive { engine in await engine.runLive() }
        case .stopLive:
            drive { engine in engine.continuation.yield(.live(.stopped)) }
        case .startRecording:
            // Here and not in the scenario: a Stop that arrives before the Task starts is not lost.
            stopRecording.withLock { $0 = false }
            running.withLock { $0 = .recording }
            drive { engine in await engine.runRecording() }
        case .stopRecording:
            stopRecording.withLock { $0 = true }
        case .separateFile(let path, _):
            running.withLock { $0 = .separation }
            drive { engine in await engine.runSeparation(source: path) }
        case .cancelJob:
            let cancelled = running.withLock { current -> Running? in
                defer { current = nil }
                return current
            }
            drive { _ in }
            switch cancelled {
            case .recording: continuation.yield(.failure(EngineFailure(.recordingCancelled)))
            case .separation: continuation.yield(.failure(EngineFailure(.separationCancelled)))
            case nil: break
            }
        case .player(let player):
            switch player {
            case .play: play()
            case .pause: stopPlaying()
            case .seek(let seconds):
                let playing = playback.withLock { state -> Bool in
                    state.position = min(max(seconds, 0), state.duration)
                    return state.task != nil
                }
                if playing { play() } else { emitPlayer(playing: false) }
            }
        case .debugMeasureDelay:
            continuation.yield(.measuredDelay(seconds: 0.98))
        case .shutdown:
            finish()
        case .loadStems(let result, let position):
            stopPlaying(emit: false)
            playback.withLock {
                $0.position = position
                $0.duration = result.duration
            }
            emitPlayer(playing: false)
        case .setTelemetry(let on):
            playback.withLock { $0.telemetry = on }
        case .setLiveLevel, .setMix, .clearStudio, .setTranspose, .scanKeys:
            break
        }
    }

    public func terminate() async {
        finish()
    }

    // MARK: - Scenarios

    private func runLive() async {
        continuation.yield(.live(.warming))
        guard await pause(fillDuration / 2) else { return }
        for step in 0...10 {
            continuation.yield(.live(.filling(fraction: Double(step) / 10)))
            guard await pause(fillDuration / 10) else { return }
        }
        continuation.yield(.live(.running))
        var levels: [Stem: Float] = Dictionary(uniqueKeysWithValues: Stem.live.map { ($0, 0.3) })
        while true {
            continuation.yield(.liveStats(LiveStats(delaySeconds: 0.98, modelMs: 96, load: 0.21,
                                                    underruns: 0, outputIsBluetooth: false)))
            for stem in Stem.live {
                let target = Float.random(in: 0.1...0.9)
                levels[stem] = (levels[stem] ?? 0) * 0.7 + target * 0.3
            }
            continuation.yield(.levels(levels))
            guard await pause(statsInterval) else { return }
        }
    }

    /// Fake peaks at 10 Hz until `stopRecording` arrives.
    private func runRecording() async {
        var tick = 0
        while !stopRecording.withLock({ $0 }) {
            guard await pause(statsInterval) else { return }
            tick += 1
            let peaks = (0..<2).map { i in Float(0.3 + 0.3 * abs(sin(Double(tick * 2 + i) / 3))) }
            continuation.yield(.recording(seconds: Double(tick) / 10, peaks: peaks))
        }
        let path = NSHomeDirectory() + "/Music/Stelix/demo/recording.wav"
        running.withLock { $0 = .separation }
        continuation.yield(.recorded(path: path))
        await runSeparation(source: path)
    }

    private func runSeparation(source: String) async {
        for step in 0...10 {
            continuation.yield(.job(progress: Double(step) / 10, step: .separating))
            guard await pause(statsInterval) else { return }
        }
        let folder = (source as NSString).deletingLastPathComponent
        let waveforms = Dictionary(uniqueKeysWithValues: Stem.studio.enumerated().map { index, stem in
            (stem, (0..<600).map { i in Float(0.5 + 0.4 * sin(Double(i) / Double(12 + index * 5))) })
        })
        running.withLock { $0 = nil }
        stopPlaying(emit: false)
        playback.withLock {
            $0.position = 0
            $0.duration = 10
        }
        continuation.yield(.stemsReady(StemsResult(
            folder: folder,
            files: Dictionary(uniqueKeysWithValues: Stem.studio.map { ($0, $0.fileName) }),
            duration: 10,
            waveforms: waveforms)))
    }

    // MARK: - Studio player

    private func play() {
        guard !finished.withLock({ $0 }) else { return }
        let tick = statsInterval / 5
        let task = Task { [self] in
            var ticks = 0
            while await pause(tick) {
                ticks += 1
                let (position, duration, telemetry) = playback.withLock { state in
                    state.position = min(state.position + tick / .seconds(1), state.duration)
                    return (state.position, state.duration, state.telemetry)
                }
                if position >= duration {
                    // End of the track, as in `StudioPlayer`: stopped there.
                    stopPlaying()
                    return
                }
                if telemetry {
                    continuation.yield(.levels(Dictionary(uniqueKeysWithValues: Stem.studio.enumerated().map { i, stem in
                        (stem, Float(0.4 + 0.3 * sin(position * 4 + Double(i))))
                    })))
                }
                if ticks % 2 == 0 { emitPlayer(playing: true) }
            }
        }
        playback.withLock { state in
            state.task?.cancel()
            state.task = task
        }
        emitPlayer(playing: true)
    }

    private func stopPlaying(emit: Bool = true) {
        playback.withLock { state in
            state.task?.cancel()
            state.task = nil
        }
        if emit { emitPlayer(playing: false) }
    }

    private func emitPlayer(playing: Bool) {
        let (position, duration) = playback.withLock { ($0.position, $0.duration) }
        continuation.yield(.player(position: position, duration: duration, playing: playing))
    }

    // MARK: - Support

    /// Replaces the scenario in progress with a new one.
    private func drive(_ body: @escaping @Sendable (DemoEngine) async -> Void) {
        guard !finished.withLock({ $0 }) else { return }
        let task = Task { [self] in await body(self) }
        driver.withLock { current in
            current?.cancel()
            current = task
        }
    }

    /// Sleeps; `false` if the scenario was cancelled.
    private func pause(_ duration: Duration) async -> Bool {
        (try? await Task.sleep(for: duration)) != nil
    }

    private func finish() {
        let first = finished.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        driver.withLock { $0?.cancel(); $0 = nil }
        playback.withLock { $0.task?.cancel(); $0.task = nil }
        continuation.finish()
    }
}
