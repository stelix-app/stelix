// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct StudioScratchTests {
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "StudioScratchTests-\(UUID().uuidString)/Stelix-Studio")
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func children(_ root: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    @Test func newFolderKeepsTheLoadedOne() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let a = try scratch.newFolder()
        scratch.loaded(a)
        let stray = try scratch.newFolder()
        let b = try scratch.newFolder()
        #expect(Self.exists(a))
        #expect(Self.exists(b))
        #expect(!Self.exists(stray))
        #expect(a.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    @Test func loadedPrunesTheOthers() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let a = try scratch.newFolder()
        scratch.loaded(a)
        let b = try scratch.newFolder()
        scratch.loaded(b)
        #expect(Self.children(root) == [b.lastPathComponent])
    }

    @Test func sameSourceReusesItsFolder() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let first = try scratch.folder(forSource: "/x/a.mp3")
        scratch.loaded(first)
        #expect(try scratch.folder(forSource: "/x/a.mp3") == first)
        let other = try scratch.folder(forSource: "/x/b.mp3")
        #expect(other != first)
        #expect(Self.exists(first))
        // A pruned folder is not found again: a new one is made.
        scratch.loaded(other)
        let again = try scratch.folder(forSource: "/x/a.mp3")
        #expect(Self.exists(again))
        #expect(again != other)
    }

    @Test func recordingKeepsItsFolder() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let recording = try scratch.newFolder()
        let path = recording.appending(path: "recording.wav").path
        #expect(try scratch.folder(forSource: path).standardizedFileURL == recording.standardizedFileURL)
        #expect(Self.exists(recording))
    }

    /// Intermediate and Pro work in `$TMPDIR/Stelix-sidecar-*`: after a kill -9 it stays there, and goes away with the rest.
    @Test func clearRemovesSidecarWorkFolders() throws {
        let root = Self.tempRoot()
        let parent = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let work = parent.appending(path: StudioScratch.sidecarWorkPrefix + "1234")
        let unrelated = parent.appending(path: "Altro")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        StudioScratch.clear(root: root)
        #expect(!Self.exists(work))
        #expect(Self.exists(unrelated))
    }

    @Test func clearRemovesEverything() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        scratch.loaded(try scratch.newFolder())
        scratch.clear()
        #expect(!Self.exists(root))
        _ = try scratch.newFolder()
        StudioScratch.clear(root: root)
        #expect(!Self.exists(root))
    }

    // MARK: The stems stay across sections (Task 10.8)

    /// Before a new engine the app keeps the folder of the stems it still shows, and nothing else.
    @Test func staticClearKeepsTheGivenFolder() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let kept = try scratch.newFolder()
        scratch.loaded(kept)
        let other = try scratch.newFolder()
        let sidecar = root.deletingLastPathComponent().appending(path: StudioScratch.sidecarWorkPrefix + "x")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        StudioScratch.clear(root: root, keeping: kept.path)
        #expect(Self.exists(kept))
        #expect(!Self.exists(other))
        #expect(!Self.exists(sidecar))

        StudioScratch.clear(root: root, keeping: nil)
        #expect(!Self.exists(root))
    }

    /// An engine that exits keeps the stems in its player (the app may show them again) and drops the rest:
    /// a recording or a job cut short.
    @Test func engineExitKeepsOnlyTheLoadedFolder() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let loaded = try scratch.newFolder()
        scratch.loaded(loaded)
        let job = try scratch.newFolder()
        let sidecar = root.deletingLastPathComponent().appending(path: StudioScratch.sidecarWorkPrefix + "y")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        scratch.clearKeepingLoaded()
        #expect(Self.exists(loaded))
        #expect(!Self.exists(job))
        #expect(!Self.exists(sidecar))
    }

    /// Without stems in the player an exiting engine leaves nothing.
    @Test func engineExitWithoutStemsLeavesNothing() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let job = try scratch.newFolder()
        scratch.clearKeepingLoaded()
        #expect(!Self.exists(job))
    }

    /// A Live engine never touches the folder: when it exits, the stems the Studio keeps from before stay.
    @Test func engineThatNeverUsedTheFolderLeavesItAlone() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let studioEngine = StudioScratch(root: root)
        let kept = try studioEngine.newFolder()
        studioEngine.loaded(kept)
        let liveEngine = StudioScratch(root: root)
        liveEngine.clearKeepingLoaded()
        #expect(Self.exists(kept))
    }

    /// Writes a stem and the leftovers of a write cut short (Task 10.10): `.<name>.partial`, `.<name>.previous`.
    private static func fillWithLeftovers(_ folder: URL) throws -> (stem: URL, leftovers: [URL]) {
        let stem = folder.appending(path: "drums.wav")
        let leftovers = [folder.appending(path: ".drums.wav.partial"), folder.appending(path: ".bass.wav.previous")]
        for url in [stem] + leftovers { try Data([1, 2, 3]).write(to: url) }
        return (stem, leftovers)
    }

    /// An engine killed while writing stems into the kept folder (Change Model) leaves temporaries there:
    /// the app drops them before the next engine, the stems stay.
    @Test func staticClearDropsWriteLeftoversInTheKeptFolder() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let kept = try scratch.newFolder()
        scratch.loaded(kept)
        let files = try Self.fillWithLeftovers(kept)

        StudioScratch.clear(root: root, keeping: kept.path)
        #expect(Self.exists(files.stem))
        for leftover in files.leftovers { #expect(!Self.exists(leftover)) }
    }

    /// The same for an engine that exits on its own and keeps the stems of its player.
    @Test func engineExitDropsWriteLeftoversInTheLoadedFolder() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let loaded = try scratch.newFolder()
        scratch.loaded(loaded)
        let files = try Self.fillWithLeftovers(loaded)

        scratch.clearKeepingLoaded()
        #expect(Self.exists(files.stem))
        for leftover in files.leftovers { #expect(!Self.exists(leftover)) }
    }

    /// Stelix died (stdin closed without `.shutdown`): nobody will show the stems again, so the exiting engine
    /// deletes them too, instead of leaving them in `$TMPDIR` until the next launch (Task 10.10).
    @Test func engineExitAfterTheAppDiedLeavesNothing() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let scratch = StudioScratch(root: root)
        let loaded = try scratch.newFolder()
        scratch.loaded(loaded)
        let sidecar = root.deletingLastPathComponent().appending(path: StudioScratch.sidecarWorkPrefix + "z")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        scratch.clearKeepingLoaded(appAlive: false)
        #expect(!Self.exists(root))
        #expect(!Self.exists(sidecar))
    }

    /// Even with Stelix dead, an engine that never used the folder leaves it alone (an engine launched by hand
    /// must not empty the folder of the Stelix that is open).
    @Test func engineThatNeverUsedTheFolderLeavesItAloneEvenAfterTheAppDied() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let studioEngine = StudioScratch(root: root)
        let kept = try studioEngine.newFolder()
        studioEngine.loaded(kept)
        StudioScratch(root: root).clearKeepingLoaded(appAlive: false)
        #expect(Self.exists(kept))
    }
}
