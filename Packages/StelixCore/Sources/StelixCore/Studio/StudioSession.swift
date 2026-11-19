// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The Studio state as the app sees it: what is being done, the stems in the player, what to retry.
/// It is pure: every action and every event returns the commands to send to the engine, and whoever uses it
/// (`StudioViewModel`) forwards them. One thing at a time: while a job runs, or until
/// the engine has answered a cancellation, another does not start (the engine would say "busy").
public struct StudioSession: Sendable, Equatable {
    public enum Stage: Equatable, Sendable {
        case idle
        /// The seconds recorded so far.
        case recording(seconds: Double)
        case separating(progress: Double, step: JobStep)
        case ready(StemsResult)
        case failed(EngineFailure)
    }

    /// The live waveform columns that are kept: more than fit in the panel.
    public static let waveCap = 600
    /// A Stop before this throws the recording away instead of separating it.
    public static let minimumRecordingSeconds = 1.0

    /// Where the stems come from: a Studio recording or a dragged or chosen file.
    public enum Source: Equatable, Sendable {
        case recording(path: String)
        case file(path: String)

        public var path: String {
            switch self {
            case .recording(let path), .file(let path): path
            }
        }
    }

    private enum Job: Equatable, Sendable {
        case record
        case file(path: String)
    }

    private enum Kind: Equatable, Sendable {
        case recording, separation
    }

    public private(set) var stage: Stage = .idle
    /// The stems loaded in the engine's player; they remain after a cancellation or a job error.
    public private(set) var result: StemsResult?
    public private(set) var position: Double = 0
    /// The last seek, until the engine gives a nearby position; `staleTicks` counts the discarded ticks.
    private var pendingSeek: PendingSeek?
    private struct PendingSeek: Sendable, Equatable {
        var target: Double
        var staleTicks: Int
    }
    static let seekTolerance = 0.25
    static let maxStaleTicks = 3
    public private(set) var playing = false
    /// The Mac has been silent for 3 s while recording: the permission may be missing.
    public private(set) var permissionSuspected = false
    /// The track of the loaded stems.
    public private(set) var source: Source?
    /// The level the loaded stems were made with.
    public private(set) var stemsLevel: StudioLevel?
    /// The folder in `~/Music/Stelix` where these stems were saved; `nil` until saved.
    public private(set) var savedFolder: String?
    /// The peaks of the recording in progress, at most `waveCap`, the most recent at the end.
    public private(set) var wave: [Float] = []

    /// The job to redo with Retry; `nil` if what failed was not a job (the player).
    private var retryJob: Job?
    /// A cancellation sent and not yet closed by the engine: its in-flight events are discarded.
    private var pendingCancel: Kind?
    /// The source of the job in progress (or the last one), which becomes `source` with its stems.
    private var jobSource: Source?
    /// The level of the job in progress (or the last one); `nil` for a recording not yet finished.
    private var jobLevel: StudioLevel?
    /// Stop sent, waiting for `.recorded`.
    private var stopRequested = false
    /// The engine has gone and the next Studio engine has not had `startCommands` yet: commands would be lost.
    private var awaitingEngine = false
    /// Play pressed while `awaitingEngine`: the next Studio engine starts playing.
    private var playOnStart = false
    /// That Play has been sent with the stems: the "stopped" states the engine sends while it loads them are
    /// not shown (the button would flip back to Play for an instant), at most `maxStaleTicks` of them.
    private var startingPlay: Int?
    /// A cancellation abandoned without an answer (`abandonCancel`): the engine may still be on the job, and
    /// until it answers it would ignore `clearStudio` (`StudioExpiry.isBusy`).
    public private(set) var cancelUnanswered = false

    public init() {}

    /// A job is running, or one is being cancelled.
    public var isBusy: Bool {
        if pendingCancel != nil { return true }
        switch stage {
        case .recording, .separating: return true
        case .idle, .ready, .failed: return false
        }
    }

    /// There are stems to save, not yet saved, and nothing in progress.
    public var canSave: Bool {
        result != nil && savedFolder == nil && !isBusy
    }

    /// One can record or load: we are in Studio, its engine is ready and nothing is in progress.
    public func canStart(mode: Mode, phase: ModePhase) -> Bool {
        mode == .studio && phase == .active && !isBusy
    }

    // MARK: - Azioni

    public mutating func record() -> [Command] {
        start(.record, level: .base)
    }

    /// Stops the recording: what is there is separated, or thrown away if under a second.
    public mutating func stop() -> [Command] {
        guard case .recording(let seconds) = stage, pendingCancel == nil, !stopRequested else { return [] }
        if seconds < Self.minimumRecordingSeconds { return cancel() }
        stopRequested = true
        return [.stopRecording]
    }

    public mutating func load(path: String, level: StudioLevel) -> [Command] {
        start(.file(path: path), level: level)
    }

    /// Redoes the failed job; after a player error it goes back to the stems (or to the start). A
    /// separation restarts with its level: `level` is needed only if the recording is what failed.
    public mutating func retry(level: StudioLevel) -> [Command] {
        guard case .failed = stage else { return [] }
        if let retryJob {
            if case .file = retryJob { return start(retryJob, level: jobLevel ?? level) }
            return start(retryJob, level: level)
        }
        stage = fallback
        return []
    }

    public mutating func cancel() -> [Command] {
        switch stage {
        case .recording: pendingCancel = .recording
        case .separating: pendingCancel = .separation
        case .idle, .ready, .failed: return []
        }
        stage = fallback
        permissionSuspected = false
        return [.cancelJob]
    }

    /// An error found by the app before asking the engine anything (unreadable file).
    /// Retry goes back to the previous stems, or to the start.
    public mutating func fail(_ message: FailureMessage) {
        guard !isBusy else { return }
        retryJob = nil
        stage = .failed(EngineFailure(message))
    }

    /// Redoes the stems of the same track at another level. Nothing if there are no stems, if the
    /// level is that of the stems or if a job is running. The previous stems remain until the new ones.
    public mutating func changeModel(to level: StudioLevel) -> [Command] {
        guard result != nil, let source, level != stemsLevel, !isBusy else { return [] }
        jobSource = source
        return start(.file(path: source.path), level: level)
    }

    /// The engine did not answer the cancellation in time (`StudioViewModel` waits a few
    /// seconds): stop waiting for it, so Record and Choose file become available again.
    public mutating func abandonCancel() {
        if pendingCancel != nil { cancelUnanswered = true }
        pendingCancel = nil
    }

    public mutating func markSaved(_ folder: String) {
        guard result != nil else { return }
        savedFolder = folder
    }

    /// The space bar: only where the play button is, with the stems ready.
    public mutating func togglePlayback() -> [Command] {
        guard hasPlayButton else { return [] }
        return playing ? pause() : play()
    }

    /// The space bar as the panel sees it: `nil` where there is no play button (the key goes on). The repeats
    /// of a held key are swallowed with no command: no system beep, and no play and pause again.
    public mutating func spaceKey(isRepeat: Bool) -> [Command]? {
        guard hasPlayButton else { return nil }
        return isRepeat ? [] : togglePlayback()
    }

    private var hasPlayButton: Bool {
        if case .ready = stage { true } else { false }
    }

    /// "To the start", left of play: back to 0, playing on if it was playing.
    public mutating func rewind() -> [Command] {
        guard case .ready = stage else { return [] }
        return seek(to: 0)
    }

    /// The engine has gone (Original, Live, a crash). The stems stay with their position, level and
    /// saved folder; a job in progress, an error on screen and the play state do not. `keepingPlayRequest`: the
    /// new engine is the Studio's, so a Play pressed while waiting for it stays (false for another section's).
    public mutating func engineStopped(keepingPlayRequest: Bool = true) {
        pendingSeek = nil
        startingPlay = nil
        if !(keepingPlayRequest && playOnStart) { playOnStart = false }
        playing = playOnStart
        permissionSuspected = false
        wave = []
        retryJob = nil
        pendingCancel = nil
        jobSource = nil
        jobLevel = nil
        stopRequested = false
        stage = fallback
        awaitingEngine = true
        cancelUnanswered = false
    }

    /// The Studio is chosen but its engine is not up yet (the previous one still shuts down, or this one starts):
    /// Play waits for it, like after `engineStopped`.
    public mutating func engineNotReady() {
        awaitingEngine = true
    }

    /// What a new Studio engine receives first: the mix, the stems the app still shows where they were, Play
    /// if it was pressed while the engine started, the telemetry if the panel is open (the engine starts with
    /// it off). Nothing without stems.
    public mutating func startCommands(mix: StemMix, telemetry: Bool) -> [Command] {
        awaitingEngine = false
        defer { playOnStart = false }
        guard let result else { return [] }
        startingPlay = playOnStart ? 0 : nil
        return [.setMix(mix), .loadStems(result, position: position)]
            + (playOnStart ? [.player(.play)] : [])
            + (telemetry ? [.setTelemetry(true)] : [])
    }

    /// While the engine starts nothing is sent: the button shows Pause at once and the engine plays when it is up.
    public mutating func play() -> [Command] {
        guard result != nil else { return [] }
        guard !awaitingEngine else {
            playOnStart = true
            playing = true
            return []
        }
        return [.player(.play)]
    }

    public mutating func pause() -> [Command] {
        guard result != nil else { return [] }
        startingPlay = nil
        guard !awaitingEngine else {
            playOnStart = false
            playing = false
            return []
        }
        return [.player(.pause)]
    }

    /// The position changes at once, so the cursor does not jump back while waiting for the engine.
    public mutating func seek(to seconds: Double) -> [Command] {
        guard let result else { return [] }
        let clamped = min(max(seconds, 0), result.duration)
        position = clamped
        pendingSeek = PendingSeek(target: clamped, staleTicks: 0)
        return [.player(.seek(seconds: clamped))]
    }

    // MARK: - Eventi

    public mutating func handle(_ event: Event, level: StudioLevel) -> [Command] {
        switch event {
        case .recording(let seconds, let peaks):
            guard pendingCancel == nil, case .recording = stage else { break }
            stage = .recording(seconds: seconds)
            wave.append(contentsOf: peaks)
            if wave.count > Self.waveCap { wave.removeFirst(wave.count - Self.waveCap) }
        case .recorded(let path):
            cancelUnanswered = false
            permissionSuspected = false
            stopRequested = false
            if pendingCancel == .recording {
                // The recording had already finished: the cancellation will find nothing to stop.
                pendingCancel = nil
                return []
            }
            guard case .recording = stage else { return [] }
            retryJob = .file(path: path)
            jobSource = .recording(path: path)
            jobLevel = level
            stage = .separating(progress: 0, step: .readingFile)
            return [.separateFile(path: path, level: level)]
        case .job(let progress, let step):
            if pendingCancel == nil, case .separating = stage { stage = .separating(progress: progress, step: step) }
        case .stemsReady(let newResult):
            // Also after a late cancellation: the engine has already loaded these stems.
            pendingCancel = nil
            cancelUnanswered = false
            result = newResult
            source = jobSource
            stemsLevel = jobLevel ?? stemsLevel ?? level
            savedFolder = nil
            position = 0
            pendingSeek = nil
            playing = false
            stage = .ready(newResult)
        case .player(let newPosition, _, let isPlaying):
            if let stale = startingPlay, !isPlaying, stale < Self.maxStaleTicks {
                startingPlay = stale + 1
            } else {
                startingPlay = nil
                playing = isPlaying
            }
            // After a seek, a tick that started earlier (position far from the requested point) does not bring
            // the cursor back; at most three, in case the seek was lost.
            if let seek = pendingSeek, abs(newPosition - seek.target) > Self.seekTolerance,
               seek.staleTicks < Self.maxStaleTicks {
                pendingSeek?.staleTicks += 1
                break
            }
            pendingSeek = nil
            position = newPosition
        case .permissionSuspected:
            if case .recording = stage { permissionSuspected = true }
        case .failure(let failure):
            handle(failure)
        case .ready, .live, .liveStats, .levels, .measuredDelay, .tempo:
            break
        }
        return []
    }

    /// An event while another section is chosen. Only stems count: a separation that ended in the last
    /// instants of its engine, already in its player and in the temporary folder (Task 10.10). Nothing is sent.
    /// Without a job to belong to (it went with its engine, or the stems were forgotten) they are not taken.
    public mutating func handleOutsideStudio(_ event: Event) {
        guard case .stemsReady = event, let jobLevel else { return }
        _ = handle(event, level: jobLevel)
    }

    private mutating func handle(_ failure: EngineFailure) {
        guard failure.code != "measure" else { return }
        // "Busy" answers a new command: the abandoned job still runs.
        if !Self.playerCodes.contains(failure.code), failure.code != Self.busyCode { cancelUnanswered = false }
        if pendingCancel != nil, !Self.playerCodes.contains(failure.code) {
            // The end of the cancelled job, however it went.
            pendingCancel = nil
            return
        }
        guard failure.code != "cancelled" else { return }
        permissionSuspected = false
        if isBusy, !(pendingCancel != nil && Self.playerCodes.contains(failure.code)) {
            // A file without audio or too long would fail again: Retry goes back to the stems.
            if Self.finalCodes.contains(failure.code) { retryJob = nil }
            stage = .failed(failure)
            return
        }
        // Player errors: "file" and "noStems" mean the stems are not loaded.
        if failure.code == "file" || failure.code == "noStems" {
            result = nil
            source = nil
            stemsLevel = nil
            savedFolder = nil
        }
        retryJob = nil
        stage = .failed(failure)
    }

    // MARK: - Supporto

    /// Errors that depend on the file and do not change on retrying.
    private static let finalCodes: Set<String> = ["unsupported", "tooLong"]
    /// Errors that come only from the player: during a cancellation they are not the answer to it.
    private static let playerCodes: Set<String> = ["output", "noStems"]
    /// Recording and separation together: the engine refuses the new job.
    private static let busyCode = EngineFailure(.alreadySeparating).code

    private var fallback: Stage {
        result.map { .ready($0) } ?? .idle
    }

    private mutating func start(_ job: Job, level: StudioLevel) -> [Command] {
        guard !isBusy else { return [] }
        var commands: [Command] = playing ? [.player(.pause)] : []
        retryJob = job
        permissionSuspected = false
        switch job {
        case .record:
            jobSource = nil
            jobLevel = nil
            stage = .recording(seconds: 0)
            wave = []
            stopRequested = false
            commands.append(.startRecording)
        case .file(let path):
            // Retrying the separation of a recording leaves it a recording.
            if jobSource?.path != path { jobSource = .file(path: path) }
            jobLevel = level
            stage = .separating(progress: 0, step: .readingFile)
            commands.append(.separateFile(path: path, level: level))
        }
        return commands
    }
}
