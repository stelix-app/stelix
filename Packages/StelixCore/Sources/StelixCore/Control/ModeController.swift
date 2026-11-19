// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Observation
import Synchronization

/// The only object that touches the engine. Every user choice cancels the transition in progress;
/// transitions run one after another, so in the end there is at most one live engine.
@MainActor @Observable public final class ModeController {
    /// The user's choice, updated at once.
    public private(set) var selected: Mode = .original
    /// Original is always `.active`.
    public private(set) var phase: ModePhase = .active
    /// Live turned itself off after minutes of silence (`.live(.stoppedForSilence)`) and the section
    /// went back to Original: Original says why, once. It goes when the panel closes or another
    /// section is chosen.
    public private(set) var liveStoppedForSilence = false
    @ObservationIgnored public var eventSink: (@MainActor (Event) -> Void)?
    /// Waits before shutting down the engine on a section change: the Save copy reads from the
    /// temporary folder, and an exiting engine prunes it (it keeps only the stems of its player).
    @ObservationIgnored public var beforeStop: (@MainActor () async -> Void)?
    /// The models `mode` needs that aren't installed, checked before every engine start. When the
    /// list isn't empty the engine doesn't start: a Live started only to fail would mute the Mac for
    /// a moment (tap `mutedWhenTapped`). The phase becomes `.failed(.missingWeights)` with the first
    /// missing model as `detail`, the same failure the engine sends as a safety net.
    @ObservationIgnored public var missingModels: (@MainActor (Mode) async -> [ModelID])?

    static let crashFailure = EngineFailure(.engineStopped)
    static let startFailure = EngineFailure(.engineLaunch)

    @ObservationIgnored private let makeEngine: @MainActor () -> EngineConnection
    @ObservationIgnored private let startCommands: @MainActor (Mode) -> [Command]
    /// The current engine, even while it prepares. Whoever shuts it down removes it from here before waiting.
    @ObservationIgnored private var engine: EngineConnection?
    /// The engine that answered `.ready` and has already received the start command: from here on
    /// `send` reaches it, even if Live is still `.preparing` (model warming up).
    @ObservationIgnored private var started: EngineConnection?
    @ObservationIgnored private var transition: Task<Void, Never>?
    /// Engines discarded outside a transition (error, crash), still to be fully shut down.
    @ObservationIgnored private var retiring: [Task<Void, Never>] = []
    @ObservationIgnored private var isShutDown = false
    /// The Task reading each engine's events, until its stream ends.
    @ObservationIgnored private var pumps: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Engines whose `lastEventsWait` is over: their stems come too late, the next engine may have pruned them.
    @ObservationIgnored private var lateClosed: Set<ObjectIdentifier> = []
    /// How long a transition waits, after the old engine's exit, for the last of its events.
    @ObservationIgnored var lastEventsWait: Duration = .seconds(1)
    /// Live was shut down for the system sleep (`systemWillSleep`).
    @ObservationIgnored private var resumeAfterWake = false

    public init(makeEngine: @escaping @MainActor () -> EngineConnection,
                startCommands: @escaping @MainActor (Mode) -> [Command]) {
        self.makeEngine = makeEngine
        self.startCommands = startCommands
    }

    /// Never blocks and never launches.
    public func select(_ mode: Mode) {
        guard !isShutDown else { return }
        selected = mode
        resumeAfterWake = false
        if mode != .original { liveStoppedForSilence = false }
        // A new choice is a new attempt: the failure on screen goes now, not when the attempt
        // runs (Live Base without its model, then Pro, flashed the red error for a frame).
        if case .failed = phase { phase = mode == .original ? .active : .preparing }
        let previous = transition
        previous?.cancel()
        transition = Task { [weak self] in
            await previous?.value
            await self?.run(mode)
        }
    }

    /// The panel has closed: the silence notice has been seen (or the panel was open when it came).
    public func panelClosed() {
        liveStoppedForSilence = false
    }

    /// Forwards only to the current engine, and only after its start command. Before that, and while it
    /// shuts down, the command is lost: whoever starts reads the current state in `startCommands`.
    public func send(_ command: Command) {
        guard let engine, engine === started else { return }
        engine.send(command)
    }

    /// Before system sleep: Live's engine is shut down, process tap included, and the section stays Live.
    /// A tap alive across sleep can deadlock coreaudiod when the output device reconfigures at wake
    /// (13/11, Live on a USB interface: no app could play audio until coreaudiod was killed).
    /// Studio is left alone: it has no tap outside a recording, which the app stops itself.
    public func systemWillSleep() async {
        guard !isShutDown, selected == .live else { return }
        let previous = transition
        previous?.cancel()
        let stop = Task { [weak self] in
            await previous?.value
            await self?.run(.original)
        }
        transition = stop
        await stop.value
        guard transition == stop, selected == .live else { return }
        resumeAfterWake = true
        phase = .preparing
    }

    /// After the wake: Live comes back if it was shut down for the sleep and nothing else was chosen meanwhile.
    public func systemDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        guard selected == .live else { return }
        select(.live)
    }

    /// For ⌘Q and "Quit Stelix": shuts everything down within about 1 s.
    public func shutdown() async {
        isShutDown = true
        transition?.cancel()
        let pending = transition
        let current = engine
        engine = nil
        let retiring = self.retiring
        self.retiring = []
        await withTaskGroup(of: Void.self) { group in
            if let current { group.addTask { await current.terminate() } }
            for task in retiring { group.addTask { await task.value } }
            if let pending { group.addTask { await pending.value } }
        }
        selected = .original
        phase = .active
    }

    /// For tests: waits for the transitions started so far to end.
    func waitForTransition() async {
        await transition?.value
    }

    // MARK: - Transition

    private func run(_ mode: Mode) async {
        guard !Task.isCancelled else { return }
        await drainRetiring()
        if let old = engine {
            phase = .stopping
            await beforeStop?()
            if engine === old { engine = nil }
            await old.terminate()
            // Stems it finished while shutting down reach the app before the next engine is made: the app
            // keeps their folder when it prunes the temporary one (Task 10.10).
            await waitForLastEvents(of: old)
            if pumps[ObjectIdentifier(old)] != nil { lateClosed.insert(ObjectIdentifier(old)) }
        }
        guard !Task.isCancelled else { return }

        guard mode != .original else {
            phase = .active
            return
        }

        phase = .preparing
        if let missingModels, let first = await missingModels(mode).first {
            guard !Task.isCancelled else { return }
            phase = .failed(EngineFailure(.missingWeights, detail: first.rawValue))
            return
        }
        guard !Task.isCancelled else { return }
        let new = makeEngine()
        engine = new
        do {
            try await new.start()
        } catch {
            if engine === new { engine = nil }
            await new.terminate()
            guard !Task.isCancelled else { return }
            phase = .failed((error as? EngineFailure) ?? Self.startFailure)
            return
        }
        guard !Task.isCancelled, engine === new else {
            if engine === new { engine = nil }
            await new.terminate()
            return
        }

        pump(new, mode: mode)
        for command in startCommands(mode) { new.send(command) }
        started = new
        if mode != .live { phase = .active }
        // Live: becomes active with `.live(.running)`, in pump.
    }

    private func pump(_ connection: EngineConnection, mode: Mode) {
        let id = ObjectIdentifier(connection)
        pumps[id] = Task { [weak self] in
            defer {
                self?.pumps[id] = nil
                self?.lateClosed.remove(id)
            }
            var lastFailure: EngineFailure?
            for await event in connection.events {
                if case .failure(let failure) = event { lastFailure = failure }
                // The controller never asks for stopLive: a `.stopped` in Live is the engine giving up
                // (no callbacks, failed rebuild). It sends `.failure` with the reason first.
                if case .live(.stopped) = event, let self, self.engine === connection,
                   mode == .live, self.phase == .active {
                    self.engine = nil
                    self.phase = .failed(lastFailure ?? Self.crashFailure)
                    self.eventSink?(event)
                    self.retire(connection)
                    return
                }
                guard let self else { return }
                guard self.engine === connection else {
                    // An engine being shut down: the rest no longer counts, but stems finished in its last
                    // instants are already in its player and in the temporary folder (Task 10.10).
                    if case .stemsReady = event, !self.lateClosed.contains(id) { self.eventSink?(event) }
                    continue
                }
                self.handle(event, from: connection, mode: mode)
            }
            // The stream has ended: if the engine is still ours, nobody asked for it.
            guard let self, self.engine === connection else { return }
            self.engine = nil
            self.phase = .failed(Self.crashFailure)
            self.retire(connection)
        }
    }

    private func handle(_ event: Event, from connection: EngineConnection, mode: Mode) {
        switch event {
        case .live(.running) where phase == .preparing && mode == .live:
            phase = .active
        case .failure(let failure) where phase == .preparing:
            engine = nil
            phase = .failed(failure)
            retire(connection)
        case .live(.stoppedForSilence) where mode == .live:
            // The engine has already removed the tap and released the model: Original shuts it down,
            // the same path as when the user turns Live off.
            eventSink?(event)
            select(.original)
            liveStoppedForSilence = true
            return
        default:
            break
        }
        eventSink?(event)
    }

    /// Until the engine's event stream ends, at most `lastEventsWait`: an exited process can still have lines
    /// in the pipe.
    private func waitForLastEvents(of connection: EngineConnection) async {
        guard let pump = pumps[ObjectIdentifier(connection)] else { return }
        let limit = lastEventsWait
        // Not a task group: `await pump.value` ignores cancellation, and the group would wait for it anyway.
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { await pump.value; once.resume() }
            timer = Task { try? await Task.sleep(for: limit); once.resume() }
        }
        timer?.cancel()
    }

    private func retire(_ connection: EngineConnection) {
        retiring.append(Task { await connection.terminate() })
    }

    private func drainRetiring() async {
        let tasks = retiring
        retiring = []
        for task in tasks { await task.value }
    }
}

/// A continuation resumed by whichever arrives first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        continuation.withLock { $0.take() }?.resume()
    }
}
