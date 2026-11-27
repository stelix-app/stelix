// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct DemoEngineTests {
    @Test func liveGoesWarmingFillingRunningThenStats() async throws {
        let engine = DemoEngine(fillDuration: .milliseconds(200), statsInterval: .milliseconds(20))
        try await engine.start()
        engine.send(.startLive(level: .intermediate, mix: .allOn(Stem.live)))
        var phases: [LivePhase] = []
        var stats: LiveStats?
        var levels: [Stem: Float]?
        for await event in engine.events {
            switch event {
            case .live(let p): phases.append(p)
            case .liveStats(let s): stats = s
            case .levels(let l): levels = l
            default: break
            }
            if stats != nil, levels != nil { break }
        }
        await engine.terminate()
        #expect(phases.first == .warming)
        #expect(phases.last == .running)
        #expect(phases.contains(.filling(fraction: 1)))
        #expect(stats == LiveStats(delaySeconds: 0.98, modelMs: 96, load: 0.21, underruns: 0, outputIsBluetooth: false))
        #expect(Set(levels?.keys ?? [:].keys) == Set(Stem.live))
    }

    @Test func studioSeparationEndsWithSixStems() async throws {
        let engine = DemoEngine(fillDuration: .milliseconds(50), statsInterval: .milliseconds(10))
        try await engine.start()
        engine.send(.separateFile(path: "/tmp/x.mp3", level: .base))
        var result: StemsResult?
        var sawProgress = false
        for await event in engine.events {
            if case .job = event { sawProgress = true }
            if case .stemsReady(let r) = event { result = r; break }
        }
        await engine.terminate()
        #expect(sawProgress)
        #expect(result?.files.count == 6)
        #expect(result?.waveforms[.piano]?.count == 600)
    }

    @Test func cancelJobIsAnsweredLikeTheRealEngine() async throws {
        let engine = DemoEngine(statsInterval: .milliseconds(50))
        try await engine.start()
        engine.send(.separateFile(path: "/tmp/x.mp3", level: .base))
        engine.send(.cancelJob)
        var answer: EngineFailure?
        for await event in engine.events {
            if case .stemsReady = event { break }
            if case .failure(let failure) = event { answer = failure; break }
        }
        await engine.terminate()
        #expect(answer?.code == "cancelled")
    }

    @Test func stopRightAfterStartRecordingIsNotLost() async throws {
        let engine = DemoEngine(statsInterval: .milliseconds(10))
        try await engine.start()
        engine.send(.startRecording)
        engine.send(.stopRecording)
        var recorded = false
        for await event in engine.events {
            if case .recorded = event { recorded = true; break }
        }
        await engine.terminate()
        #expect(recorded)
    }

    /// Like `StudioPlayer`: while it plays, the position goes forward and, with telemetry, the six levels arrive.
    @Test func studioPlayTicksLikeThePlayerUntilPause() async throws {
        let engine = DemoEngine(statsInterval: .milliseconds(10))
        try await engine.start()
        // Without ticks the loops below would wait forever: after 2 s the stream ends and the test fails.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(2))
            await engine.terminate()
        }
        defer { watchdog.cancel() }
        engine.send(.setTelemetry(true))
        engine.send(.player(.play))
        var positions: [Double] = []
        var levels: [Stem: Float]?
        for await event in engine.events {
            if case .player(let position, _, true) = event { positions.append(position) }
            if case .levels(let l) = event { levels = l }
            if positions.count >= 3, levels != nil { break }
        }
        engine.send(.player(.pause))
        var paused = false
        for await event in engine.events {
            if case .player(_, _, false) = event { paused = true; break }
        }
        await engine.terminate()
        #expect(positions == positions.sorted())
        #expect((positions.last ?? 0) > (positions.first ?? 0))
        #expect(Set(levels?.keys ?? [:].keys) == Set(Stem.studio))
        #expect(paused)
    }

    @Test func terminateEndsStreamAndIsIdempotent() async throws {
        let engine = DemoEngine()
        try await engine.start()
        await engine.terminate()
        await engine.terminate()
        var count = 0
        for await _ in engine.events { count += 1 }
        #expect(count <= 1) // at most the .ready already queued
    }
}
