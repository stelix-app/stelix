// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization

/// The Studio's temporary folder: recordings and stems live here until the user
/// presses Save. Each track has its own folder `root/<UUID>`; only the one with the stems in the
/// player and the one of the job in progress remain, the others are deleted as soon as they are no longer needed.
/// The stems outlive their engine (Task 10.8): the Studio shows them again after Original or Live. An engine
/// that exits keeps only the folder of its player; the app keeps only the folder of the stems it shows
/// before every new engine, and empties everything at launch, on Quit and after 10 minutes of closed panel.
public final class StudioScratch: Sendable {
    public static let defaultRoot = FileManager.default.temporaryDirectory
        .appending(path: "Stelix-Studio", directoryHint: .isDirectory)

    /// The working folders of Intermediate and Pro (`SidecarJob`), next to `root`: they too
    /// must not survive a killed engine.
    public static let sidecarWorkPrefix = "Stelix-sidecar-"

    static let failure = EngineFailure(.tempFolder)

    private struct State {
        /// The folder of the stems loaded in the player.
        var loaded: String?
        /// Files dragged or chosen → their folder, to redo their stems at another level.
        var sources: [String: String] = [:]
        /// This instance has made or loaded a folder. An engine that never did (Live) leaves `root`
        /// alone when it exits: the stems the Studio keeps from an earlier engine are there.
        var used = false
    }

    private let root: URL
    private let state = Mutex(State())

    public init(root: URL = defaultRoot) {
        self.root = root.standardizedFileURL
    }

    /// New folder `root/<UUID>`; deletes all the others except the loaded one.
    public func newFolder() throws(EngineFailure) -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Self.failure
        }
        state.withLock { $0.used = true }
        prune(keeping: folder)
        return folder
    }

    /// Where to write the stems of `path`: a recording inside `root` keeps its folder, a
    /// file already seen finds its own (if it is still there), the others get a new one. Deletes as
    /// `newFolder`.
    public func folder(forSource path: String) throws(EngineFailure) -> URL {
        let parent = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        if parent.deletingLastPathComponent().path == root.path {
            state.withLock { $0.used = true }
            prune(keeping: parent)
            return parent
        }
        if let known = state.withLock({ $0.sources[path] }), FileManager.default.fileExists(atPath: known) {
            let folder = URL(fileURLWithPath: known, isDirectory: true)
            prune(keeping: folder)
            return folder
        }
        let folder = try newFolder()
        state.withLock { $0.sources[path] = folder.path }
        return folder
    }

    /// The stems of `folder` are in the player: all the other folders are deleted.
    public func loaded(_ folder: URL) {
        state.withLock {
            $0.loaded = folder.standardizedFileURL.lastPathComponent
            $0.used = true
        }
        prune(keeping: folder)
    }

    public func clear() {
        state.withLock { $0 = State() }
        Self.clear(root: root)
    }

    /// For the engine that exits: the stems of its player stay, the rest goes (a recording or a job cut
    /// short, the sidecar's work folders). `appAlive` false: Stelix died (stdin closed without `.shutdown`),
    /// nobody will show the stems again and they go too. An engine that never used the folder touches nothing.
    public func clearKeepingLoaded(appAlive: Bool = true) {
        let (used, loaded) = state.withLock { state in
            state.sources = [:]
            return (state.used, state.loaded)
        }
        guard used else { return }
        Self.clear(root: root, keeping: appAlive ? loaded.map { root.appending(path: $0).path } : nil)
    }

    /// Only without a live engine (or from the engine that is exiting): also deletes the sidecar's jobs.
    /// `keeping`: the folder of stems to keep, inside `root`.
    public static func clear(root: URL = defaultRoot, keeping: String? = nil) {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        let kept = keeping.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        if let kept, kept.deletingLastPathComponent().path == root.path, fm.fileExists(atPath: kept.path) {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != kept.lastPathComponent {
                try? fm.removeItem(at: root.appending(path: name))
            }
            // A write cut short by a killed engine (`StemFiles`): its temporaries, up to 2.5 GB, are hidden.
            for name in (try? fm.contentsOfDirectory(atPath: kept.path)) ?? []
            where name.hasPrefix(".") && (name.hasSuffix(StemFiles.partialSuffix) || name.hasSuffix(StemFiles.previousSuffix)) {
                try? fm.removeItem(at: kept.appending(path: name))
            }
        } else {
            try? fm.removeItem(at: root)
        }
        let parent = root.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasPrefix(sidecarWorkPrefix) {
            try? fm.removeItem(at: parent.appending(path: name))
        }
    }

    private func prune(keeping folder: URL) {
        let fm = FileManager.default
        let keep: Set<String> = state.withLock { state in
            let keep = Set([folder.standardizedFileURL.lastPathComponent] + [state.loaded].compactMap { $0 })
            state.sources = state.sources.filter { keep.contains(URL(fileURLWithPath: $0.value).lastPathComponent) }
            return keep
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: root.appending(path: name))
        }
    }
}
