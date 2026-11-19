// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization
import Testing
@testable import StelixCore

/// State shared between a test's fakes: how many "processes" are alive.
final class Shared: Sendable {
    private let counts = Mutex((alive: 0, peak: 0))
    var alive: Int { counts.withLock { $0.alive } }
    /// The maximum number of live engines at the same moment, over the whole test.
    var peak: Int { counts.withLock { $0.peak } }

    func launched() {
        counts.withLock { c in
            c.alive += 1
            c.peak = max(c.peak, c.alive)
        }
    }

    func exited() { counts.withLock { $0.alive -= 1 } }
}

/// A fake engine that behaves like the real process: it lives from `start()` until it exits,
/// and when it exits the event stream ends.
final class FakeEngine: EngineConnection {
    struct Config: Sendable {
        var startDelay: Duration = .zero
        var failStart = false
        var ignoresShutdown = false
        /// The start also finishes if the task was cancelled (like a process answering .ready).
        var ignoresCancellation = false
        /// SIGKILL is not instant: the exit arrives 100 ms later.
        var asyncKill = false
        /// startLive is answered only with `.warming`, like a model being loaded.
        var liveStaysWarming = false
        /// Sent after `.shutdown`, before exiting: like a separation that ends while the engine shuts down.
        var lastWords: [Event] = []
        /// The event stream stays open after the exit, like a pipe something else still holds.
        var eventsOutliveExit = false
    }

    private struct State {
        var launched = false
        var exited = false
        var terminateCalls = 0
        var killed = false
        var received: [Command] = []
        var termination: Task<Void, Never>?
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let exitStream: AsyncStream<Void>
    private let exitContinuation: AsyncStream<Void>.Continuation
    private let state = Mutex(State())
    private let config: Config
    private let shared: Shared

    init(config: Config, shared: Shared) {
        self.config = config
        self.shared = shared
        (events, continuation) = AsyncStream.makeStream()
        (exitStream, exitContinuation) = AsyncStream.makeStream()
    }

    var terminateCalls: Int { state.withLock { $0.terminateCalls } }
    var killed: Bool { state.withLock { $0.killed } }
    var received: [Command] { state.withLock { $0.received } }

    func start() async throws {
        state.withLock { $0.launched = true }
        shared.launched()
        if config.ignoresCancellation {
            let delay = config.startDelay
            await Task.detached { try? await Task.sleep(for: delay) }.value
        } else {
            try await Task.sleep(for: config.startDelay)
        }
        if config.failStart {
            exit()
            throw EngineFailure(.audioStart)
        }
        continuation.yield(.ready)
    }

    func send(_ command: Command) {
        let exited = state.withLock { s in
            if !s.exited { s.received.append(command) }
            return s.exited
        }
        guard !exited else { return }
        switch command {
        case .startLive:
            continuation.yield(.live(.warming))
            if !config.liveStaysWarming { continuation.yield(.live(.running)) }
        case .shutdown where !config.ignoresShutdown:
            for event in config.lastWords { continuation.yield(event) }
            exit()
        default:
            break
        }
    }

    func terminate() async {
        let task = state.withLock { s -> Task<Void, Never> in
            s.terminateCalls += 1
            if let t = s.termination { return t }
            let t = Task {
                _ = await EngineStop.perform(
                    requestShutdown: { self.send(.shutdown) },
                    waitForExit: { for await _ in self.exitStream {} },
                    kill: {
                        self.state.withLock { $0.killed = true }
                        if self.config.asyncKill {
                            Task.detached {
                                try? await Task.sleep(for: .milliseconds(100))
                                self.exit()
                            }
                        } else {
                            self.exit()
                        }
                    })
            }
            s.termination = t
            return t
        }
        await task.value
    }

    /// The process dies by itself, as with `kill -9`.
    func crash() { exit() }

    /// An event the engine sends on its own initiative.
    func push(_ event: Event) { continuation.yield(event) }

    private func exit() {
        let first = state.withLock { s -> Bool in
            guard s.launched, !s.exited else { return false }
            s.exited = true
            return true
        }
        guard first else { return }
        shared.exited()
        if !config.eventsOutliveExit { continuation.finish() }
        exitContinuation.finish()
    }
}

@MainActor final class Harness {
    let shared = Shared()
    private(set) var engines: [FakeEngine] = []
    var controller: ModeController!

    init(_ config: FakeEngine.Config = .init(), studioStart: [Command] = []) {
        controller = ModeController(
            makeEngine: { [unowned self] in
                let engine = FakeEngine(config: config, shared: self.shared)
                self.engines.append(engine)
                return engine
            },
            startCommands: { mode in
                switch mode {
                case .live: [.startLive(level: .intermediate, mix: .allOn(Stem.live))]
                case .studio: studioStart
                case .original: []
                }
            })
    }

    convenience init(startDelay: Duration) { self.init(.init(startDelay: startDelay)) }

    var alive: Int { shared.alive }

    /// Waits for the transition in progress to finish and for the phase to stop being transient.
    func settle() async {
        await controller.waitForTransition()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            switch controller.phase {
            case .preparing, .stopping: try? await Task.sleep(for: .milliseconds(5))
            default: return
            }
        }
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor struct ModeControllerTests {
    static let lateStems = StemsResult(folder: "/tmp/new", files: [.drums: "/tmp/new/drums.wav"], duration: 30,
                                       waveforms: [:])

    /// A separation that ends while its engine shuts down (a section change in its last instants): its stems
    /// still reach the app, which shows them again in the next Studio (Task 10.10). Before, they were lost.
    @Test func stemsOfAStoppingEngineStillArrive() async {
        let h = Harness(.init(lastWords: [.stemsReady(Self.lateStems)]))
        var received: [Event] = []
        h.controller.eventSink = { received.append($0) }
        h.controller.select(.studio)
        await h.settle()
        h.controller.select(.original)
        await h.settle()
        #expect(received.contains(.stemsReady(Self.lateStems)))
    }

    /// Only the stems: the rest of what a stopping engine says (its player, a failure) no longer counts.
    @Test func otherEventsOfAStoppingEngineAreDropped() async {
        let h = Harness(.init(lastWords: [.player(position: 1, duration: 30, playing: false),
                                          .failure(EngineFailure(.separationCancelled))]))
        var received: [Event] = []
        h.controller.eventSink = { received.append($0) }
        h.controller.select(.studio)
        await h.settle()
        h.controller.select(.original)
        await h.settle()
        // `.ready`, from the start, may or may not have been read by then.
        #expect(received.allSatisfy { $0 == .ready })
    }

    /// Stems later than `lastEventsWait` are dropped: the next engine is already there, and their folder may
    /// be gone with the prune.
    @Test func stemsAfterTheWaitAreDropped() async {
        let h = Harness(.init(eventsOutliveExit: true))
        h.controller.lastEventsWait = .milliseconds(50)
        var received: [Event] = []
        h.controller.eventSink = { if case .stemsReady = $0 { received.append($0) } }
        h.controller.select(.studio)
        await h.settle()
        let old = h.engines[0]
        h.controller.select(.live)
        await h.settle()
        old.push(.stemsReady(Self.lateStems))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.isEmpty)
    }

    /// The late stems arrive before the next engine is made: the app keeps their folder when it prunes the
    /// temporary one, and the next Studio engine loads them.
    @Test func stemsOfAStoppingEngineArriveBeforeTheNextEngine() async {
        var log: [String] = []
        let shared = Shared()
        let controller = ModeController(
            makeEngine: {
                log.append("engine")
                return FakeEngine(config: .init(lastWords: [.stemsReady(Self.lateStems)]), shared: shared)
            },
            startCommands: { _ in [] })
        controller.eventSink = { event in
            if case .stemsReady = event { log.append("stems") }
        }
        controller.select(.studio)
        await controller.waitForTransition()
        controller.select(.live)
        await controller.waitForTransition()
        #expect(log == ["engine", "stems", "engine"])
    }
    @Test func startsInOriginalActive() {
        let h = Harness()
        #expect(h.controller.selected == .original)
        #expect(h.controller.phase == .active)
        #expect(h.engines.isEmpty)
    }

    /// A process tap alive across system sleep can deadlock coreaudiod (seen on 13/11 with Live on a USB
    /// interface): Live is shut down before sleep, tap included, and comes back after the wake.
    @Test func liveIsShutDownBeforeSleepAndBackAfterWake() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        #expect(h.alive == 1)
        await h.controller.systemWillSleep()
        #expect(h.alive == 0)
        #expect(h.controller.selected == .live)
        h.controller.systemDidWake()
        await h.settle()
        #expect(h.alive == 1)
        #expect(h.engines.count == 2)
        #expect(h.engines.last?.received.first == .startLive(level: .intermediate, mix: .allOn(Stem.live)))
    }

    /// Studio has no tap outside a recording, and its stems live with its engine: sleep leaves it alone.
    @Test func sleepLeavesStudioAndOriginalAlone() async {
        let h = Harness()
        h.controller.select(.studio)
        await h.settle()
        await h.controller.systemWillSleep()
        h.controller.systemDidWake()
        await h.settle()
        #expect(h.alive == 1)
        #expect(h.engines.count == 1)
    }

    /// Another choice during the sleep wins: the wake does not bring Live back.
    @Test func wakeDoesNotOverrideAChoiceMadeMeanwhile() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        await h.controller.systemWillSleep()
        h.controller.select(.original)
        await h.settle()
        h.controller.systemDidWake()
        await h.settle()
        #expect(h.alive == 0)
        #expect(h.controller.selected == .original)
    }

    @Test func rapidToggleEndsOnLastWithOneEngine() async {
        let h = Harness(startDelay: .milliseconds(50))
        for i in 0..<20 { h.controller.select(i.isMultiple(of: 2) ? .live : .studio) }
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.selected == .live)
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
        #expect(h.shared.peak <= 1)
    }

    @Test func liveStudioOriginalBurstEndsWithNoEngine() async {
        let h = Harness(startDelay: .milliseconds(30))
        h.controller.select(.live)
        h.controller.select(.studio)
        h.controller.select(.original)
        await h.settle()
        #expect(h.controller.selected == .original)
        #expect(h.controller.phase == .active)
        #expect(h.alive == 0)
        #expect(h.shared.peak <= 1)
    }

    @Test func cancelledAfterSuccessfulStartTerminatesEngine() async throws {
        // The start succeeds, but meanwhile the user has chosen something else.
        let h = Harness(.init(startDelay: .milliseconds(200), ignoresCancellation: true))
        h.controller.select(.live)
        try await Task.sleep(for: .milliseconds(10))
        h.controller.select(.original)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 0)
        #expect(h.engines.first?.terminateCalls ?? 0 >= 1)
        #expect(h.engines.first?.received == [.shutdown]) // no startLive
    }

    @Test func killedEngineIsGoneBeforeTheNextStarts() async {
        let h = Harness(.init(ignoresShutdown: true, asyncKill: true))
        h.controller.select(.studio)
        await h.settle()
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.engines.first?.killed == true)
        #expect(h.alive == 1)
        #expect(h.shared.peak <= 1)
    }

    @Test func switchWhileOldEngineStopsKeepsOneAlive() async throws {
        // The old engine ignores .shutdown: it shuts down in ~0.9 s. Meanwhile the choice changes again.
        let h = Harness(.init(ignoresShutdown: true, asyncKill: true))
        h.controller.select(.studio)
        await h.settle()
        h.controller.select(.live)
        try await Task.sleep(for: .milliseconds(20))
        h.controller.select(.studio)
        await h.settle()
        #expect(h.controller.selected == .studio)
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
        #expect(h.shared.peak <= 1)
    }

    @Test func liveThenOriginalTerminatesEngine() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
        h.controller.select(.original)
        await h.settle()
        #expect(h.controller.selected == .original)
        #expect(h.controller.phase == .active)
        #expect(h.alive == 0)
        #expect(h.engines.first?.terminateCalls ?? 0 >= 1)
    }

    @Test func liveStaysPreparingUntilRunning() async {
        let h = Harness()
        h.controller.select(.studio)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.engines.last?.received.isEmpty == true)
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        if case .startLive = h.engines.last?.received.first {} else {
            Issue.record("Live must send startLive")
        }
    }

    @Test func switchDuringPreparingCancels() async throws {
        let h = Harness(startDelay: .milliseconds(500))
        h.controller.select(.live)
        try await Task.sleep(for: .milliseconds(10))
        #expect(h.controller.phase == .preparing)
        h.controller.select(.studio)
        await h.settle()
        #expect(h.controller.selected == .studio)
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
        #expect(h.engines.count == 2)
        #expect(h.engines[0].terminateCalls >= 1)
    }

    @Test func startFailureGoesToFailedAndOriginalRecovers() async {
        let h = Harness(.init(failStart: true))
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .failed(EngineFailure(.audioStart)))
        #expect(h.alive == 0)
        h.controller.select(.original)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 0)
    }

    @Test func liveWithMissingModelNeverStartsEngine() async {
        let h = Harness()
        h.controller.missingModels = { mode in mode == .live ? [.htdemucsFT] : [] }
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .failed(EngineFailure(.missingWeights, detail: "htdemucs_ft")))
        #expect(h.engines.isEmpty)
    }

    /// A new choice is a new attempt: the old failure goes at once, not when the attempt runs.
    /// (Live Base without its model, then Pro: the red error flashed for a frame.)
    @Test func selectingAgainLeavesTheFailureAtOnce() async {
        let h = Harness()
        var missing: [ModelID] = [.htdemucs]
        h.controller.missingModels = { _ in missing }
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .failed(EngineFailure(.missingWeights, detail: "htdemucs")))
        missing = []
        h.controller.select(.live)
        #expect(h.controller.phase == .preparing)
        h.controller.select(.original)
        #expect(h.controller.phase != .failed(EngineFailure(.missingWeights, detail: "htdemucs")))
    }

    @Test func failureLeavesAtOnceForAnotherSection() async {
        let h = Harness()
        h.controller.missingModels = { mode in mode == .live ? [.htdemucs] : [] }
        h.controller.select(.live)
        await h.settle()
        h.controller.select(.studio)
        #expect(h.controller.phase == .preparing)
        h.controller.select(.live)
        await h.settle()
        h.controller.select(.original)
        #expect(h.controller.phase == .active)
    }

    @Test func studioStartsEvenWithMissingModels() async {
        let h = Harness()
        h.controller.missingModels = { mode in mode == .live ? [.htdemucs] : [] }
        h.controller.select(.studio)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
    }

    @Test func liveStartsOnceModelArrives() async {
        let h = Harness(.init(liveStaysWarming: false))
        var missing: [ModelID] = [.htdemucs]
        h.controller.missingModels = { _ in missing }
        h.controller.select(.live)
        await h.settle()
        #expect(h.engines.isEmpty)
        missing = []
        h.controller.select(.live)
        await h.settle()
        #expect(h.engines.count == 1)
        #expect(h.controller.phase == .active)
    }

    @Test func runningLiveStopsWhenRecheckFindsMissingModel() async {
        let h = Harness()
        var missing: [ModelID] = []
        h.controller.missingModels = { _ in missing }
        h.controller.select(.live)
        await h.settle()
        #expect(h.alive == 1)
        missing = [.htdemucsFT]
        h.controller.select(.live)
        await h.settle()
        #expect(h.alive == 0)
        #expect(h.controller.phase == .failed(EngineFailure(.missingWeights, detail: "htdemucs_ft")))
    }

    @Test func failureEventDuringPreparingGoesToFailed() async {
        // Live that starts and receives .failure before .running.
        let engine = FailingLiveEngine()
        let controller = ModeController(
            makeEngine: { engine },
            startCommands: { _ in [.startLive(level: .base, mix: .allOn(Stem.live))] })
        controller.select(.live)
        await controller.waitForTransition()
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.phase == .preparing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.phase == .failed(EngineFailure(.tap)))
        await engine.waitForTerminate()
        #expect(engine.terminateCalls == 1)
    }

    @Test func unexpectedTerminationGoesToFailed() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        h.engines.last?.crash()
        await h.waitFor { h.controller.phase != .active }
        #expect(h.controller.phase == .failed(EngineFailure(.engineStopped)))
        #expect(h.alive == 0)
        #expect(h.controller.selected == .live)
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
    }

    @Test func crashWhilePreparingGoesToFailed() async {
        // The model warms up (only .warming) and the engine dies before .running.
        let h = Harness(.init(liveStaysWarming: true))
        h.controller.select(.live)
        await h.controller.waitForTransition()
        #expect(h.controller.phase == .preparing)
        h.engines.last?.crash()
        await h.waitFor { h.controller.phase != .preparing }
        #expect(h.controller.phase == .failed(EngineFailure(.engineStopped)))
        #expect(h.alive == 0)
    }

    @Test func stopWaitsForBeforeStop() async throws {
        // Save is copying from the temporary folder: the engine (which empties it on exit) waits.
        let h = Harness()
        let (gate, open) = AsyncStream<Void>.makeStream()
        h.controller.beforeStop = { for await _ in gate {} }
        h.controller.select(.studio)
        await h.settle()
        h.controller.select(.original)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.controller.phase == .stopping)
        #expect(h.alive == 1)
        #expect(h.engines.first?.received.contains(.shutdown) == false)
        open.finish()
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 0)
    }

    @Test func liveGivingUpGoesToFailedWithItsMessage() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        h.engines.last?.push(.failure(EngineFailure(.noAudio)))
        h.engines.last?.push(.live(.stopped))
        await h.waitFor { h.controller.phase != .active }
        #expect(h.controller.phase == .failed(EngineFailure(.noAudio)))
        await h.waitFor { h.alive == 0 }
        #expect(h.alive == 0)
        h.controller.select(.live)
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
    }

    @Test func liveStoppedForSilenceGoesToOriginalWithNotice() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        #expect(!h.controller.liveStoppedForSilence)
        h.engines.last?.push(.live(.stoppedForSilence))
        await h.waitFor { h.controller.selected == .original && h.alive == 0 }
        await h.settle()
        #expect(h.controller.selected == .original)
        #expect(h.controller.phase == .active)
        #expect(h.alive == 0)
        #expect(h.controller.liveStoppedForSilence)
    }

    @Test func silenceNoticeLeavesWhenThePanelCloses() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        h.engines.last?.push(.live(.stoppedForSilence))
        await h.waitFor { h.controller.liveStoppedForSilence }
        await h.settle()
        h.controller.select(.original)
        await h.settle()
        #expect(h.controller.liveStoppedForSilence)
        h.controller.panelClosed()
        #expect(!h.controller.liveStoppedForSilence)
        #expect(h.controller.selected == .original)
    }

    @Test func silenceNoticeLeavesForAnotherSection() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        h.engines.last?.push(.live(.stoppedForSilence))
        await h.waitFor { h.controller.liveStoppedForSilence }
        await h.settle()
        h.controller.select(.studio)
        #expect(!h.controller.liveStoppedForSilence)
        await h.settle()
        h.controller.select(.live)
        await h.settle()
        #expect(!h.controller.liveStoppedForSilence)
        #expect(h.controller.phase == .active)
    }

    @Test func failureWhileLiveRunsKeepsItActive() async {
        let h = Harness()
        h.controller.select(.live)
        await h.settle()
        h.engines.last?.push(.failure(EngineFailure(.outputSetup)))
        h.engines.last?.push(.live(.rebuilding))
        h.engines.last?.push(.live(.running))
        await h.settle()
        #expect(h.controller.phase == .active)
        #expect(h.alive == 1)
    }

    @Test func shutdownCompletesWithinOneSecond() async {
        let h = Harness(.init(ignoresShutdown: true))
        h.controller.select(.studio)
        await h.settle()
        #expect(h.alive == 1)
        let started = ContinuousClock.now
        await h.controller.shutdown()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(1100))
        #expect(h.engines.first?.killed == true)
        #expect(h.alive == 0)
    }

    @Test func shutdownDuringPreparingLeavesNoEngine() async {
        let h = Harness(startDelay: .milliseconds(500))
        h.controller.select(.live)
        try? await Task.sleep(for: .milliseconds(20))
        await h.controller.shutdown()
        #expect(h.alive == 0)
        h.controller.select(.live)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.engines.count == 1)
    }

    @Test func sendIgnoredWithoutEngine() async {
        let h = Harness(startDelay: .milliseconds(100))
        h.controller.send(.stopLive)
        h.controller.select(.studio)
        h.controller.send(.cancelJob)
        await h.settle()
        #expect(h.engines.first?.received.isEmpty == true)
        h.controller.send(.setTelemetry(true))
        #expect(h.engines.first?.received == [.setTelemetry(true)])
    }

    /// Mix and telemetry changed while the model warms up are not lost.
    @Test func sendReachesLiveEngineWhileItWarms() async {
        let h = Harness(.init(liveStaysWarming: true))
        h.controller.select(.live)
        await h.controller.waitForTransition()
        #expect(h.controller.phase == .preparing)
        let mix = StemMix.allOn(Stem.live).applying(.noVoice)
        h.controller.send(.setMix(mix))
        h.controller.send(.setTelemetry(true))
        #expect(h.engines.last?.received == [
            .startLive(level: .intermediate, mix: .allOn(Stem.live)), .setMix(mix), .setTelemetry(true),
        ])
    }

    /// Before the engine answers `.ready` nothing starts: startLive remains the first command.
    @Test func sendDroppedBeforeEngineHasStarted() async throws {
        let h = Harness(.init(startDelay: .milliseconds(200), liveStaysWarming: true))
        h.controller.select(.live)
        try await Task.sleep(for: .milliseconds(20))
        h.controller.send(.setTelemetry(true))
        await h.controller.waitForTransition()
        #expect(h.engines.last?.received == [.startLive(level: .intermediate, mix: .allOn(Stem.live))])
    }

    /// The Studio coming back with its stems needs more than one command: all of them arrive, in order,
    /// before anything sent from outside.
    @Test func everyStartCommandArrivesInOrder() async {
        let result = StemsResult(folder: "/t/a", files: [.drums: "/t/a/drums.wav"], duration: 10, waveforms: [:])
        let start: [Command] = [.setMix(.allOn(Stem.studio)), .loadStems(result, position: 3), .setTelemetry(true)]
        let h = Harness(studioStart: start)
        h.controller.select(.studio)
        await h.settle()
        h.controller.send(.player(.play))
        #expect(h.engines.last?.received == start + [.player(.play)])
    }

    @Test func eventsReachSink() async {
        let h = Harness()
        var seen: [Event] = []
        h.controller.eventSink = { seen.append($0) }
        h.controller.select(.live)
        await h.settle()
        await h.waitFor { seen.contains(.live(.running)) }
        #expect(seen.contains(.live(.warming)))
        #expect(seen.contains(.live(.running)))
    }
}

/// Starts, then answers startLive with an error.
final class FailingLiveEngine: EngineConnection {
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let terminations = Mutex(0)

    init() { (events, continuation) = AsyncStream.makeStream() }

    var terminateCalls: Int { terminations.withLock { $0 } }

    /// The controller shuts the engine down in a separate task: wait for it to get there.
    func waitForTerminate() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while terminateCalls == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func start() async throws {}

    func send(_ command: Command) {
        if case .startLive = command {
            continuation.yield(.live(.warming))
            continuation.yield(.failure(EngineFailure(.tap)))
        }
    }

    func terminate() async {
        terminations.withLock { $0 += 1 }
        continuation.finish()
    }
}
