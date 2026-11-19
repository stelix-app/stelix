// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import Foundation
import Observation
import StelixCore
import UniformTypeIdentifiers

/// What the Studio asks of the panel while the file picker is open.
@MainActor protocol PanelHolding: AnyObject {
    /// Suspends closing by outside click and Esc.
    var holdOpen: Bool { get set }
    var isVisible: Bool { get }
    /// The panel's window level: the file picker goes above.
    var windowLevel: NSWindow.Level { get }
    /// Reopens the panel where it was, if it has closed in the meantime, and makes it key.
    func reopen()
}

/// The Studio state for the view. The stage logic lives in `StudioSession` (StelixCore,
/// tested); here duration and level are persisted, the mix sending is throttled, the file
/// picker is opened and commands are forwarded to `ModeController.send`. Never the audio directly.
@MainActor @Observable final class StudioViewModel {
    typealias Stage = StudioSession.Stage

    static let levelKey = "studio.level"

    var level: StudioLevel {
        didSet {
            guard level != oldValue else { return }
            defaults.set(level.rawValue, forKey: Self.levelKey)
        }
    }

    var mix: StemMix {
        didSet {
            guard mix != oldValue else { return }
            scheduleMixSend()
        }
    }

    private(set) var session = StudioSession()
    /// RMS per stem while the player plays, only with the panel open.
    private(set) var levels: [Stem: Float] = [:]
    /// Save is copying the stems into `~/Music/Stelix`.
    private(set) var saving = false
    /// "Change model" pressed: the picker is free again, the next level separates the track again.
    private(set) var changingModel = false
    /// The file picker is open: Record and the rest wait, otherwise the file chosen after
    /// a Record would be lost (the engine is busy).
    private(set) var choosing = false
    /// "Change Model" towards a level whose models aren't there: its banner shows over the stems,
    /// and once the download ends the song is separated again at that level.
    private(set) var pendingLevel: StudioLevel?

    var stage: Stage { session.stage }
    var position: Double { session.position }
    var playing: Bool { session.playing }
    var permissionSuspected: Bool { session.permissionSuspected }
    /// The level of the loaded stems, while the picker is locked on it; `nil` if it is free.
    var lockedLevel: StudioLevel? {
        guard session.result != nil, !changingModel else { return nil }
        return session.stemsLevel
    }
    /// One can record or load: we are in the Studio, engine ready and no job in progress.
    var canStart: Bool {
        guard let controller else { return false }
        return !saving && !needsDownload && session.canStart(mode: controller.selected, phase: controller.phase)
    }

    /// The chosen level lacks a model: Record, Choose File and drop wait for the download.
    var needsDownload: Bool { !missingModels(level).isEmpty }

    /// The models of `level` that aren't installed. Set by the app from `ModelLibrary`; the views
    /// read the library through it, so they update when a model arrives.
    @ObservationIgnored var missingModels: (StudioLevel) -> [ModelID] = { _ in [] }

    /// How Record, Choose file and the level appear: off only with a job in progress, not in the
    /// tenths of a second while the engine starts (an off glass button loses its color: entering
    /// the Studio, Record went from white to red). A click at that instant is stopped by `canStart`.
    var looksAvailable: Bool {
        !saving && !session.isBusy && !choosing
    }

    /// The Studio engine is starting: commands do not arrive yet, the view says so.
    var preparing: Bool {
        controller?.selected == .studio && controller?.phase == .preparing
    }

    @ObservationIgnored weak var controller: ModeController?
    @ObservationIgnored weak var panel: PanelHolding?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var throttle = SendThrottle(interval: 1 / LiveViewModel.mixSendsPerSecond)
    /// The switches from before a solo, to put back when the stem is held again. Not saved across launches.
    @ObservationIgnored private var soloMemory = SoloMemory()
    @ObservationIgnored private var panelOpen = false
    /// When the stems are forgotten with the panel closed, and the Task that waits for it.
    @ObservationIgnored private var expiry = StudioExpiry()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// Empties the temporary folder with no Studio engine to ask. Set by the app, which owns the folder
    /// (not with --demo-engine or --snapshot: a real Stelix may be open).
    @ObservationIgnored var clearScratch: () -> Void = {}
    /// The Save copy in progress: on exit we wait, before emptying the temporary folder.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Counts the cancellations: the timeout counts only for the last one.
    @ObservationIgnored private var cancelCount = 0
    static let cancelTimeout = 5.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        level = StudioLevel.initial(stored: defaults.string(forKey: Self.levelKey))
        mix = .allOn(Stem.studio)
    }

    // MARK: - View commands

    func record() {
        guard canStart, !choosing else { return }
        changingModel = false
        send(session.record())
    }

    /// Stop: what is there is separated (under a second it is thrown away).
    func stop() {
        send(session.stop())
    }

    /// Before system sleep: a recording stops as if Stop had been pressed, and this waits (at most 2 s)
    /// for the engine to close its tap. Outside a recording it does nothing.
    func stopRecordingForSleep() async {
        guard case .recording = stage else { return }
        stop()
        let deadline = ContinuousClock.now + .seconds(2)
        while case .recording = stage, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A dragged or chosen file. If Stelix cannot read it, the error is right here.
    func load(_ url: URL) {
        guard canStart else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            session.fail(.fileNoAccess)
            return
        }
        changingModel = false
        send(session.load(path: url.path, level: level))
    }

    /// `NSOpenPanel` with `begin`, never `runModal`: the app activates first, the panel stays open
    /// (and if it closes anyway, it reopens), the picker sits above the panel.
    func chooseFile() {
        guard canStart, !choosing else { return }
        choosing = true
        panel?.holdOpen = true
        NSApp.activate()

        let open = NSOpenPanel()
        open.allowedContentTypes = [.audio, .movie]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        if let level = panel?.windowLevel { open.level = NSWindow.Level(rawValue: level.rawValue + 1) }
        open.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.choosing = false
                self.panel?.holdOpen = false
                self.panel?.reopen()
                if response == .OK, let url = open.url { self.load(url) }
            }
        }
    }

    func cancel() {
        let commands = session.cancel()
        send(commands)
        guard !commands.isEmpty else { return }
        cancelCount += 1
        let count = cancelCount
        // If the engine does not answer (a stuck engine, or the old DemoEngine), the Studio does not
        // stay stuck: after a few seconds it stops waiting.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.cancelTimeout))
            guard let self, self.cancelCount == count else { return }
            self.session.abandonCancel()
        }
    }

    func retry() {
        send(session.retry(level: level))
    }

    func play() {
        noteEngineState()
        send(session.play())
    }

    /// The space bar, as in Logic. `false` when there is no play button to press: the key goes on. The repeats
    /// of a held key are swallowed (`true`) without playing and pausing again.
    func spaceKey(isRepeat: Bool) -> Bool {
        // Only the error is on screen: a Play kept for later would start the stems at Try Again.
        guard !hiddenByFailure else { return false }
        noteEngineState()
        guard let commands = session.spaceKey(isRepeat: isRepeat) else { return false }
        send(commands)
        return true
    }

    /// The "to the start" button, left of play.
    func rewind() {
        send(session.rewind())
    }

    func pause() {
        noteEngineState()
        send(session.pause())
    }

    /// With the engine failed the panel shows only the error, not the Studio (`PanelView`), and the space bar
    /// has no play button to press. The missing weights left by Live keep the Studio on screen.
    var hiddenByFailure: Bool {
        guard case .failed(let failure) = controller?.phase else { return false }
        return failure.message != .missingWeights
    }

    /// Play and Pause before the Studio engine is up (the previous engine still shuts down, or this one starts)
    /// wait for it: `ModeController.send` would lose them.
    private func noteEngineState() {
        guard let controller, controller.selected == .studio, controller.phase != .active else { return }
        session.engineNotReady()
    }

    func seek(_ seconds: Double) {
        send(session.seek(to: seconds))
    }

    func beginModelChange() {
        guard session.result != nil, canStart else { return }
        changingModel = true
    }

    func endModelChange() {
        changingModel = false
    }

    func cancelPendingLevel() {
        pendingLevel = nil
    }

    /// A download or an import ended: a pending "Change Model" whose models are now all there starts.
    func modelsArrived() {
        guard let pending = pendingLevel, missingModels(pending).isEmpty else { return }
        pendingLevel = nil
        guard session.result != nil, canStart else { return }
        changingModel = true
        choose(pending)
    }

    /// A click on the picker. Free: it is the level of the next job. After "Change model": a
    /// different level separates the track again, the same one just closes. Locked: nothing.
    func choose(_ newLevel: StudioLevel) {
        if changingModel {
            changingModel = false
            guard newLevel != session.stemsLevel else { return }
            guard missingModels(newLevel).isEmpty else {
                pendingLevel = newLevel
                return
            }
            pendingLevel = nil
            // The file may have disappeared or become unreadable after the first separation.
            if case .file(let path) = session.source, !FileManager.default.isReadableFile(atPath: path) {
                session.fail(.fileNoAccess)
                return
            }
            // `level` stays that of the stems you hear: it becomes the new one only with the new stems
            // (`stemsReady`), not if the job is cancelled or fails.
            send(session.changeModel(to: newLevel))
            return
        }
        guard lockedLevel == nil else { return }
        level = newLevel
    }

    func apply(_ preset: Preset) {
        soloMemory.forget()
        mix = mix.applying(preset)
    }

    func setEnabled(_ stem: Stem, _ on: Bool) {
        soloMemory.forget()
        mix.controls[stem]?.enabled = on
    }

    /// Holding a stem's icon: that stem alone, or back to the switches from before its solo.
    func hold(_ stem: Stem) {
        mix = soloMemory.hold(stem, in: mix)
    }

    func setVolume(_ stem: Stem, _ volume: Float) {
        mix.controls[stem]?.volume = min(max(volume, 0), 1)
    }

    /// Copies the stems (and the recording, if they come from there) into a new folder of `~/Music/Stelix`,
    /// with the current date. The copy runs off the MainActor: 20 minutes are about 2.5 GB.
    func save() {
        guard session.canSave, !saving, let result = session.result, let source = session.source else { return }
        saving = true
        let recording: URL?
        let sourceName: String?
        switch source {
        case .recording(let path):
            recording = URL(fileURLWithPath: path)
            sourceName = nil
        case .file(let path):
            recording = nil
            sourceName = URL(fileURLWithPath: path).lastPathComponent
        }
        let date = Date()
        // The names of the saved files are in the language of whoever uses Stelix; inside they stay in English.
        let names = Dictionary(uniqueKeysWithValues: Stem.allCases.map { ($0, Copy.savedFileName($0)) })
        let recordingName = Copy.savedRecordingFileName
        // Each saved stem says in its metadata that a model separated it, and which one.
        let provenance = StemProvenance(software: AppInfo.software,
                                        models: ModelCatalog.models(for: session.stemsLevel ?? level))
        saveTask = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { () -> Result<URL, EngineFailure> in
                do {
                    return .success(try StemSaver.save(result, recording: recording, sourceName: sourceName, date: date,
                                                       names: { names[$0] ?? $0.fileName }, recordingName: recordingName,
                                                       provenance: provenance))
                } catch {
                    return .failure(EngineFailure(StemSaver.isOutOfSpace(error) ? .saveNoSpace : .saveFailed))
                }
            }.value
            guard let self else { return }
            self.saving = false
            // Other stems have arrived in the meantime: these are no longer the ones to save.
            guard self.session.result == result else { return }
            switch saved {
            case .success(let folder): self.session.markSaved(folder.path)
            case .failure(let failure): self.session.fail(failure.message)
            }
        }
    }

    /// Waits for Save to finish (⌘Q): quitting halfway would leave a partial folder in Music.
    func finishSaving() async {
        await saveTask?.value
    }

    /// Opens in Finder the folder where the stems were saved.
    func revealInFinder() {
        guard let folder = session.savedFolder else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
    }

    func openAudioPrivacySettings() {
        NSWorkspace.shared.open(LiveViewModel.audioPrivacyURL)
    }

    /// Level for the meter, from 0 to 1: the RMS in dB between -60 and 0, as in Live.
    func meter(_ stem: Stem) -> Double {
        guard let rms = levels[stem], rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(max((db + 60) / 60, 0), 1)
    }

    // MARK: - From the app

    /// A new engine is about to be born (any section): the old one is gone with its job, the stems stay
    /// (Task 10.8). If their files have gone from the temporary folder, there is nothing to show again.
    func resetForNewEngine() {
        // A Play pressed while waiting is for the Studio's engine only.
        session.engineStopped(keepingPlayRequest: controller?.selected == .studio)
        if let result = session.result,
           !result.files.values.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
            session = StudioSession()
        }
        levels = [:]
        changingModel = false
        pendingLevel = nil
    }

    /// The folder of the stems the Studio still shows: the one to keep before a new engine.
    var keptFolder: String? { session.result?.folder }

    /// What a new Studio engine receives first (`StudioSession.startCommands`): called once per engine.
    func takeStartCommands() -> [Command] {
        session.startCommands(mix: mix, telemetry: panelOpen)
    }

    /// Telemetry is turned on and off by `LiveViewModel.setPanelOpen`. Here: whether to turn it on again
    /// when the stems arrive (the engine starts with telemetry off), and the 10 minutes after which a closed
    /// panel forgets the stems (Task 10.8). Never with the panel open.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        expiryTask?.cancel()
        expiryTask = nil
        if open {
            expiry.panelOpened()
        } else {
            expiry.panelClosed(at: Self.now)
            watchExpiry()
        }
    }

    // MARK: - Forgetting the stems

    /// Seconds on the same clock the wait sleeps on: `ContinuousClock` keeps counting while the Mac
    /// sleeps, so a night of sleep with the panel closed counts as closed panel.
    private static let origin = ContinuousClock.now
    private static var now: Double {
        let elapsed = (ContinuousClock.now - origin).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private var busy: Bool {
        StudioExpiry.isBusy(session: session,
                            studioEngineAlive: controller?.selected == .studio && controller?.phase == .active,
                            saving: saving)
    }

    /// One look now, then sleeps until the next. With no stems and nothing running, no Task at all:
    /// Original at rest does not wake up for this.
    private func watchExpiry() {
        switch expiry.check(at: Self.now, hasStems: session.result != nil, busy: busy) {
        case .stop:
            return
        case .clear:
            forgetStems()
        case .wait(let seconds):
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds), clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.expiryTask = nil
                self.watchExpiry()
            }
        }
    }

    /// The Studio goes back to the start. The Studio engine, if it is the one alive, empties its player and the
    /// folder; otherwise the app empties the folder (Live never uses it, Original has no engine).
    private func forgetStems() {
        if controller?.selected == .studio, controller?.phase == .active {
            controller?.send(.clearStudio)
        } else {
            clearScratch()
        }
        session = StudioSession()
        levels = [:]
        changingModel = false
        pendingLevel = nil
    }

    func handle(_ event: Event) {
        // Once the Studio is left, the engine that shuts down must no longer receive commands from here
        // (an in-flight `recorded` would start a separation). Only its last stems are kept (Task 10.10).
        guard controller?.selected == .studio else {
            guard case .stemsReady = event else { return }
            let before = session.result
            session.handleOutsideStudio(event)
            guard session.result != before else { return }
            adoptedStems()
            // The panel may have closed with nothing to forget: now there is, and the 10 minutes start.
            if !panelOpen {
                expiryTask?.cancel()
                expiry.panelClosed(at: Self.now)
                watchExpiry()
            }
            return
        }
        switch event {
        case .levels(let newLevels):
            levels = newLevels
        case .stemsReady:
            send(session.handle(event, level: level))
            adoptedStems()
            // The engine's player has its own mix: the one chosen here is sent to it.
            controller?.send(.setMix(mix))
            if panelOpen { controller?.send(.setTelemetry(true)) }
        case .player(_, _, let isPlaying):
            send(session.handle(event, level: level))
            if !isPlaying { levels = [:] }
        default:
            send(session.handle(event, level: level))
            // A player error can remove the stems: without stems there is no model to change.
            if session.result == nil { changingModel = false }
        }
    }

    // MARK: - Supporto

    /// New stems in the session, in the Studio or after it was left.
    private func adoptedStems() {
        levels = [:]
        changingModel = false
        // New stems: the switches from before a solo belong to the old ones.
        soloMemory.forget()
        // The picker and the preference follow the level the stems were made with.
        if let stemsLevel = session.stemsLevel { level = stemsLevel }
    }

    private func send(_ commands: [Command]) {
        for command in commands { controller?.send(command) }
    }

    private func scheduleMixSend() {
        let now = ProcessInfo.processInfo.systemUptime
        switch throttle.request(at: now) {
        case .sendNow:
            controller?.send(.setMix(mix))
        case .sendAt(let at):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(at - now, 0)))
                guard let self else { return }
                self.throttle.fired(at: ProcessInfo.processInfo.systemUptime)
                self.controller?.send(.setMix(self.mix))
            }
        case .alreadyScheduled:
            break
        }
    }
}
