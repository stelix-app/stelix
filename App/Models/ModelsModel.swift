// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore

/// What About says about the app itself, kept in one place.
enum AppInfo {
    /// The copyright holder: the author attribution that NOTICE asks every version to keep in About.
    static let copyrightHolder = "Gabriele Carsana"
    /// The public repository: About shows it and the update check reads its latest release. Nil hides both.
    static let repositoryURL: URL? = URL(string: "https://github.com/stelix-app/stelix")
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    /// The app's name and version as the saved stems carry them in their metadata ("Stelix 1.0").
    static var software: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
        let version = info?["CFBundleShortVersionString"] as? String
        return [name, version].compactMap { $0 }.joined(separator: " ")
    }

    /// The license texts that travel inside the app: `scripts/build.sh` copies them into Resources,
    /// read-only, because the GPL and the third-party licenses ask for a copy with every binary.
    enum Document: String {
        case license = "LICENSE"
        case notices = "THIRD_PARTY_NOTICES"
    }

    static func url(of document: Document) -> URL? {
        Bundle.main.url(forResource: document.rawValue, withExtension: "txt")
    }

    /// Opens the bundled text in the default editor. A build without the bundled copy (from Xcode)
    /// falls back to the license on the web.
    @MainActor static func open(_ document: Document) {
        if let url = url(of: document) {
            NSWorkspace.shared.open(url)
        } else if document == .license {
            NSWorkspace.shared.open(licenseURL)
        }
    }
}

/// What the views need around `ModelLibrary`: whether a model can be removed now, and the file
/// picker of "Add Model…". The download logic lives in `ModelLibrary` (StelixCore, tested).
@MainActor @Observable final class ModelsModel {
    static let allOfferClosedKey = "models.allOfferClosed"

    let library: ModelLibrary
    @ObservationIgnored weak var controller: ModeController?
    @ObservationIgnored weak var panel: PanelHolding?
    @ObservationIgnored private var choosing = false
    @ObservationIgnored private let defaults: UserDefaults
    /// "Not Now" on the offer in Original: it doesn't come back.
    private(set) var allOfferClosed: Bool

    init(library: ModelLibrary, defaults: UserDefaults = .standard) {
        self.library = library
        self.defaults = defaults
        allOfferClosed = defaults.bool(forKey: Self.allOfferClosedKey)
    }

    /// The offer in Original: while some model is missing and it wasn't closed. A download started
    /// from it keeps it on screen until the end, with its bar.
    var showsAllOffer: Bool {
        guard !allOfferClosed else { return false }
        let all = ModelID.allCases
        let downloading = library.download.map { !Set($0.ids).isDisjoint(with: all) } ?? false
        return !library.missing(all).isEmpty || downloading
    }

    func closeAllOffer() {
        allOfferClosed = true
        defaults.set(true, forKey: Self.allOfferClosedKey)
        if let notice = library.notice, notice == library.missing(ModelID.allCases) { library.dismissNotice() }
    }

    /// Removing a model while an engine may be reading it isn't allowed: only in Original.
    var canRemove: Bool { controller?.selected == .original }

    /// `NSOpenPanel` with `begin`, like the Studio's Choose File: the panel stays open and the
    /// picker goes above it. The check (SHA-256, up to 700 MB) runs off the main actor.
    func chooseFile() {
        guard !choosing, !library.importing else { return }
        choosing = true
        panel?.holdOpen = true
        NSApp.activate()

        let open = NSOpenPanel()
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        if let level = panel?.windowLevel { open.level = NSWindow.Level(rawValue: level.rawValue + 1) }
        open.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.choosing = false
                self.panel?.holdOpen = false
                self.panel?.reopen()
                guard response == .OK, let url = open.url else { return }
                let library = self.library
                Task { await library.importFile(url) }
            }
        }
    }
}
