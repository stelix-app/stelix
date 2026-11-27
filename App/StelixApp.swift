// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import os
import StelixCore

/// Launch arguments:
/// - `--demo-engine`: uses `DemoEngine` instead of the StelixEngine process;
/// - `--open-panel <mode>`: opens the panel on the given mode;
/// - `--snapshot <path.png> <mode>`: with DemoEngine, opens the panel on the mode, waits 1.5 s,
///   saves the content as PNG and exits.
/// - `--no-models`: the models folder is an empty temporary one, as on a Mac that never
///   downloaded them (snapshots of the banner).
/// - `--show <settings|about|notice|settings-all|update|update-notice>`: in a snapshot, opens
///   Settings, About, the download notice of the mode's level, Settings with the notice of
///   Download All, or the update banner (closed or open) for a made-up newer version.
/// - `--update-feed <url>`: asks this address instead of the repository's latest release, for the
///   local test of updates (http://127.0.0.1 allowed). The signature check stays.
struct LaunchOptions {
    enum Show: String {
        case settings, about, notice, settingsAll = "settings-all", update, updateNotice = "update-notice"
    }

    var demoEngine = false
    var openPanel: Mode?
    var snapshot: (url: URL, mode: Mode)?
    var noModels = false
    var show: Show?
    var updateFeed: URL?

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--demo-engine":
                options.demoEngine = true
            case "--no-models":
                options.noModels = true
            case "--show":
                options.show = rest.popFirst().flatMap(Show.init(rawValue:))
            case "--update-feed":
                options.updateFeed = rest.popFirst().flatMap(URL.init(string:))
            case "--open-panel":
                options.openPanel = rest.popFirst().flatMap(Mode.init(rawValue:))
            case "--snapshot":
                if let path = rest.popFirst(), let mode = rest.popFirst().flatMap(Mode.init(rawValue:)) {
                    options.snapshot = (URL(fileURLWithPath: path), mode)
                    options.demoEngine = true
                }
            default:
                break // system arguments (-NSDocumentRevisionsDebugMode etc.)
            }
        }
        return options
    }
}

@main
@MainActor final class StelixApp: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "io.github.stelix-app.stelix", category: "app")
    private static var shared: StelixApp?

    private let options: LaunchOptions
    /// Falso in --snapshot e --demo-engine.
    private let ownsScratch: Bool
    private let router = EventRouter()
    private let live: LiveViewModel
    private let studio: StudioViewModel
    private let modeController: ModeController
    private let models: ModelsModel
    private let updates: UpdateCenter?
    private var updateTimer: Timer?
    private let settings = SettingsModel()
    private let panel: PanelController
    private var statusItem: StatusItemController?
    private var sigterm: DispatchSourceSignal?
    private var sleepWatcher: SystemSleepWatcher?
    private var isTerminating = false

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = StelixApp(options: .parse(CommandLine.arguments))
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    init(options: LaunchOptions) {
        self.options = options
        let demo = options.demoEngine
        let defaults = options.snapshot == nil ? UserDefaults.standard : Self.snapshotDefaults()
        let live = LiveViewModel(defaults: defaults)
        let studio = StudioViewModel(defaults: defaults)
        self.live = live
        self.studio = studio
        // Without models the Studio snapshot stays at the start, where the banner is.
        let snapshotStudio = options.snapshot?.mode == .studio && !options.noModels
        // Snapshot and DemoEngine do not touch the temporary folder: a real Stelix may be open.
        let ownsScratch = options.snapshot == nil && !demo
        self.ownsScratch = ownsScratch
        modeController = ModeController(
            makeEngine: {
                live.resetForNewEngine()
                studio.resetForNewEngine()
                // The old engine is already off: what it left (a crash, a job cut short) goes, the stems
                // the Studio still shows stay (Task 10.8).
                if ownsScratch { StudioScratch.clear(keeping: studio.keptFolder) }
                if demo { return DemoEngine() }
                let url = Bundle.main.url(forAuxiliaryExecutable: "StelixEngine")
                    ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/StelixEngine")
                return ProcessEngineConnection(executableURL: url)
            },
            startCommands: { mode in
                switch mode {
                case .live: live.startCommands
                // The Studio snapshot wants it listening: DemoEngine fakes a separation.
                case .studio where snapshotStudio: studio.takeStartCommands()
                    + [.separateFile(path: NSHomeDirectory() + "/Music/Stelix/demo/demo.wav", level: studio.level)]
                case .studio: studio.takeStartCommands()
                case .original: []
                }
            })
        let library = ModelLibrary(store: Self.modelStore(options), fetcher: URLSessionFetcher())
        models = ModelsModel(library: library, defaults: defaults)
        let updates = Self.makeUpdates(options, defaults: defaults)
        self.updates = updates
        panel = PanelController(controller: modeController, live: live, studio: studio, settings: settings,
                                models: models, updates: updates, defaults: defaults)
        super.init()
        models.controller = modeController
        models.panel = panel
        live.modelsMissing = { !library.missing(ModelCatalog.models(for: $0)).isEmpty }
        studio.missingModels = { library.missing(ModelCatalog.models(for: $0)) }
        // Only the Live is checked before its engine starts: the Studio's engine opens no tap and
        // loads no model until a job, which StudioViewModel holds back while a model is missing.
        // The files are looked at again each time: one removed by hand counts as missing.
        modeController.missingModels = { [live] mode in
            guard mode == .live else { return [] }
            library.refresh()
            return library.missing(ModelCatalog.models(for: live.level))
        }
        // The last choice wins: if the Live is still waiting for this level's model, it starts.
        library.onInstalled = { [modeController, live, studio] in
            if modeController.selected == .live, case .failed(let failure) = modeController.phase,
               failure.message == .missingWeights, library.missing(ModelCatalog.models(for: live.level)).isEmpty {
                modeController.select(.live)
            }
            studio.modelsArrived()
        }
        live.controller = modeController
        studio.controller = modeController
        studio.panel = panel
        if ownsScratch { studio.clearScratch = { StudioScratch.clear() } }
        router.live = live
        router.studio = studio
        router.mode = { [modeController] in modeController.selected }
        modeController.eventSink = { [router] event in router.route(event) }
        // A section change waits for Save: the old engine, on exiting, prunes the temporary folder.
        modeController.beforeStop = { [studio] in await studio.finishSaving() }
    }

    /// `Models/` in Application Support, or an empty temporary one with `--no-models`.
    private static func modelStore(_ options: LaunchOptions) -> ModelStore {
        guard options.noModels else { return ModelStore() }
        let empty = FileManager.default.temporaryDirectory.appending(path: "Stelix-no-models-\(UUID().uuidString)")
        return ModelStore(destination: empty, sources: [])
    }

    /// The update check, or nil while there's nowhere to ask (no public repository yet, Task 10.0)
    /// or the app has no version. A snapshot gets a made-up newer release and no network.
    private static func makeUpdates(_ options: LaunchOptions, defaults: UserDefaults) -> UpdateCenter? {
        let info = Bundle.main.infoDictionary
        guard let current = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) else { return nil }
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appending(path: "Downloads")
        // Next to the models: the README's uninstall already removes this folder.
        let work = URL.applicationSupportDirectory.appending(path: "Stelix/Updates")
        if options.snapshot != nil {
            // Every snapshot has it (the toggle and Check Now in Settings); only --show update finds one.
            return UpdateCenter(current: current, source: SnapshotReleaseSource(current: current),
                                fetcher: URLSessionFetcher(), verifier: nil, defaults: defaults,
                                downloads: downloads, work: work)
        }
        guard let feed = options.updateFeed ?? AppInfo.repositoryURL.flatMap(GitHubRelease.latestURL(repository:))
        else { return nil }
        let loopback = options.updateFeed.map(GitHubRelease.isLoopback) ?? false
        let fetcher = URLSessionFetcher(allows: { url in
            ModelFetchPolicy.allows(url) || loopback && url.map(GitHubRelease.isLoopback) == true
        })
        return UpdateCenter(current: current, source: URLSessionReleaseSource(url: feed, allowLoopback: loopback),
                            fetcher: fetcher, verifier: DiskImageCheck.runningApp(), defaults: defaults,
                            downloads: downloads, work: work, appName: Copy.appName, allowLoopback: loopback)
    }

    private static let openPanelNotification = SingleInstance.openPanelNotification(
        bundleID: Bundle.main.bundleIdentifier ?? "io.github.stelix-app.stelix")

    /// Another running Stelix of this user, if this one has to give way to it.
    private static func otherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
        let me = NSRunningApplication.current
        let instances = (running + [me]).map {
            SingleInstance.Instance(pid: $0.processIdentifier, launched: $0.launchDate)
        }
        guard let pid = SingleInstance.other(among: instances, me: me.processIdentifier) else { return nil }
        return running.first { $0.processIdentifier == pid }
    }

    /// Snapshots always start from the default values, without touching the user's.
    private static func snapshotDefaults() -> UserDefaults {
        let name = "io.github.stelix-app.stelix.snapshot"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Another Stelix is already running: before touching anything, it is asked to open its panel and this
        // one exits (`SingleInstance`). `exit`, not `terminate`: terminate would empty the temporary folder.
        if ownsScratch, let other = Self.otherInstance() {
            Self.log.notice("another instance is running (pid \(other.processIdentifier, privacy: .public)): exiting")
            DistributedNotificationCenter.default().postNotificationName(
                Self.openPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
            other.activate()
            exit(0)
        }
        // What was left by a crash or a kill -9.
        if ownsScratch {
            StudioScratch.clear()
            models.library.clearLeftovers()
            updates?.clearLeftovers()
        }
        statusItem = StatusItemController(panel: panel, controller: modeController, live: live, studio: studio,
                                          library: models.library, updates: updates)
        if ownsScratch, let updates { startUpdateChecks(updates) }
        installSigterm()
        if ownsScratch {
            // No process tap across system sleep: Live goes off and comes back, a recording stops.
            let watcher = SystemSleepWatcher(
                willSleep: { [modeController, studio] in
                    await studio.stopRecordingForSleep()
                    await modeController.systemWillSleep()
                },
                didWake: { [modeController] in modeController.systemDidWake() })
            watcher.start()
            sleepWatcher = watcher
        }
        if ownsScratch {
            DistributedNotificationCenter.default().addObserver(
                forName: Self.openPanelNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { StelixApp.shared?.statusItem?.open() }
            }
        }

        if let snapshot = options.snapshot {
            takeSnapshot(of: snapshot.mode, to: snapshot.url)
        } else if let mode = options.openPanel {
            modeController.select(mode)
            statusItem?.open()
            if options.show == .notice { models.library.requestDownload(ModelID.allCases) }
        }
    }

    /// At launch and then every hour, a look at whether a day has passed since the last check
    /// (`UpdateCenter.checkIfDue`): a Mac that stays on for weeks still hears of a new version.
    private func startUpdateChecks(_ updates: UpdateCenter) {
        Task { await updates.checkIfDue() }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await updates.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Answers `.terminateLater` and finishes in a MainActor Task. That is why `NSApp.terminate`
    /// must never be called from inside a Task or a MainActor job: terminate opens a nested
    /// run loop that waits for the answer, and the MainActor jobs that give it would no longer start
    /// (this is the block seen with SIGTERM). Call it from an AppKit action or from
    /// `RunLoop.main.perform`, as `installSigterm` does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        panel.hide()
        Task {
            await studio.finishSaving(cancellingTransposed: true)
            await modeController.shutdown()
            if ownsScratch { StudioScratch.clear() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// SIGTERM takes the same path as ⌘Q: engine shut down before exiting.
    private func installSigterm() {
        // A handler that does nothing, not SIG_IGN: the engine starts with SIGTERM at default.
        SignalCatch.withoutAction(SIGTERM)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Not inside the GCD block: terminate opens a nested run loop that waits for
            // shutdown(), and the MainActor jobs go through the same main queue. From the run loop, yes.
            RunLoop.main.perform {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
        source.resume()
        sigterm = source
    }

    private func takeSnapshot(of mode: Mode, to url: URL) {
        panel.plainBackground = true
        // A click elsewhere on the Mac (someone using it) would close the panel before the PNG.
        panel.holdOpen = true
        modeController.select(mode)
        // Without a visible menu bar (e.g. from a script) the panel opens at the center of the screen.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = statusItem?.anchor ?? .zero
        panel.show(anchor: anchor == .zero ? NSRect(x: screen.midX, y: screen.maxY, width: 0, height: 0) : anchor)
        switch options.show {
        case .settings:
            settings.open()
        case .about:
            settings.open()
            settings.showAbout()
        case .settingsAll:
            settings.open()
            models.library.requestDownload(ModelID.allCases)
        case .update, .updateNotice:
            let show = options.show
            Task { [updates] in
                await updates?.checkNow()
                if show == .updateNotice { updates?.showDetails() }
            }
        case .notice:
            switch mode {
            case .original: models.library.requestDownload(ModelID.allCases)
            case .live: models.library.requestDownload(ModelCatalog.models(for: live.level))
            case .studio: models.library.requestDownload(ModelCatalog.models(for: studio.level))
            }
        case nil:
            break
        }
        Task {
            // The Studio arrives listening after DemoEngine's fake separation (about 2.9 s).
            try? await Task.sleep(for: .milliseconds(mode == .studio ? 3500 : 2500))
            var code: Int32 = 1
            if let png = panel.renderPNG() {
                do {
                    try png.write(to: url)
                    code = 0
                } catch {
                    Self.log.error("snapshot: \(error.localizedDescription, privacy: .public)")
                }
            }
            await modeController.shutdown()
            exit(code)
        }
    }
}
