// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import StelixCore

@MainActor struct ModelLibraryTests {
    nonisolated private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static let contents: [String: Data] = [
        "BS-Roformer-SW.ckpt": Data(repeating: 1, count: 3_000),
        "BS-Roformer-SW.yaml": Data(repeating: 2, count: 1_000),
        "htdemucs.safetensors": Data(repeating: 3, count: 500),
        "htdemucs_config.json": Data("{}".utf8),
    ]

    nonisolated private static let catalog: ModelCatalog = {
        func file(_ name: String, _ folder: ModelFolder) -> ModelFile {
            ModelFile(name: name, folder: folder, url: URL(string: "https://example.com/\(name)")!,
                      sha256: sha(contents[name]!), size: Int64(contents[name]!.count))
        }
        return ModelCatalog(packages: [
            ModelPackage(id: .roformerSW, files: [file("BS-Roformer-SW.ckpt", .roformer), file("BS-Roformer-SW.yaml", .roformer)],
                         author: "a", source: "example.com", license: .undeclaredUnverified),
            ModelPackage(id: .htdemucs, files: [file("htdemucs.safetensors", .demucs), file("htdemucs_config.json", .demucs)],
                         author: "a", source: "example.com", license: .demucsUnclear),
        ])
    }()

    /// Writes the bytes of `contents` (or `override`) in one go, or throws a chosen error, or
    /// writes nothing and waits to be cancelled.
    private final class Fetcher: ModelFetcher, @unchecked Sendable {
        var override: [String: Data] = [:]
        var failure: [String: any Error] = [:]
        var hang = false
        let started = AsyncStream<Void>.makeStream()
        /// These files wait for `release` before writing.
        var held: Set<String> = []
        private let gates = Mutex<[String: CheckedContinuation<Void, Never>]>([:])
        private let released = Mutex<Set<String>>([])
        let calls = Mutex<[String]>([])

        func release(_ name: String) {
            let waiter = gates.withLock { g -> CheckedContinuation<Void, Never>? in
                released.withLock { _ = $0.insert(name) }
                return g.removeValue(forKey: name)
            }
            waiter?.resume()
        }

        func fetch(_ url: URL, expectedSize: Int64, to destination: URL,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
            let name = url.lastPathComponent
            calls.withLock { $0.append(name) }
            if held.contains(name) {
                await withCheckedContinuation { c in
                    let go = gates.withLock { g -> Bool in
                        if released.withLock({ $0.contains(name) }) { return true }
                        g[name] = c
                        return false
                    }
                    if go { c.resume() }
                }
            }
            try Task.checkCancellation()
            if let error = failure[name] { throw error }
            if hang {
                started.continuation.yield()
                try await Task.sleep(for: .seconds(60))
            }
            let data = override[name] ?? ModelLibraryTests.contents[name]!
            try data.write(to: destination)
            progress(Int64(data.count))
        }
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        let fetcher = Fetcher()
        init(sources: [URL] = []) {
            root = FileManager.default.temporaryDirectory.appending(path: "ModelLibraryTests-\(UUID().uuidString)")
            store = ModelStore(destination: root.appending(path: "Models"), sources: sources, catalog: ModelLibraryTests.catalog)
        }
        @MainActor func library() -> ModelLibrary {
            ModelLibrary(installer: ModelInstaller(store: store, fetcher: fetcher, availableSpace: { _ in nil }))
        }
        func put(_ name: String, in folder: String) throws {
            let dir = store.destination.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ModelLibraryTests.contents[name]!.write(to: dir.appending(path: name))
        }
        var downloads: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: store.downloadsDirectory.path)) ?? []
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func startsWithWhatIsOnDisk() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("htdemucs.safetensors", in: "demucs")
        try f.put("htdemucs_config.json", in: "demucs")
        let library = f.library()
        #expect(library.installed == [.htdemucs])
        #expect(library.missing([.htdemucs, .roformerSW]) == [.roformerSW])
    }

    @Test func launchDeletesHalfDownloadsLeftByACrash() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.store.downloadsDirectory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: f.store.downloadsDirectory.appending(path: "BS-Roformer-SW.ckpt"))
        f.library().clearLeftovers()
        #expect(f.downloads.isEmpty)
    }

    @Test func missingBytesCountsOnlyAbsentFiles() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("BS-Roformer-SW.yaml", in: "roformer")
        let library = f.library()
        #expect(library.missingBytes([.roformerSW]) == 3_000)
    }

    @Test func requestDownloadListsOnlyMissingModels() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("htdemucs.safetensors", in: "demucs")
        try f.put("htdemucs_config.json", in: "demucs")
        let library = f.library()
        library.requestDownload([.htdemucs, .roformerSW])
        #expect(library.notice == [.roformerSW])
        library.dismissNotice()
        #expect(library.notice == nil)
    }

    @Test func requestDownloadWithNothingMissingOpensNothing() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("htdemucs.safetensors", in: "demucs")
        try f.put("htdemucs_config.json", in: "demucs")
        let library = f.library()
        library.requestDownload([.htdemucs])
        #expect(library.notice == nil)
    }

    @Test func confirmedDownloadInstallsAndNotifies() async {
        let f = Fixture()
        defer { f.cleanup() }
        let library = f.library()
        var notified = 0
        library.onInstalled = { notified += 1 }
        library.requestDownload([.htdemucs, .roformerSW])
        library.confirmDownload()
        #expect(library.notice == nil)
        #expect(library.download?.ids == [.htdemucs, .roformerSW])
        #expect(library.download?.total == 4_502)
        await library.waitForDownload()
        #expect(library.download == nil)
        #expect(library.installed == [.htdemucs, .roformerSW])
        #expect(library.problems.isEmpty)
        #expect(notified == 1)
    }

    @Test func cancelledDownloadLeavesNothingInstalled() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.hang = true
        let library = f.library()
        var notified = 0
        library.onInstalled = { notified += 1 }
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        var started = f.fetcher.started.stream.makeAsyncIterator()
        _ = await started.next()
        library.cancelDownload()
        await library.waitForDownload()
        #expect(library.download == nil)
        #expect(library.problems.isEmpty)
        #expect(library.installed.isEmpty)
        #expect(f.downloads.isEmpty)
        #expect(notified == 0)
        // A new attempt starts clean.
        f.fetcher.hang = false
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(library.installed == [.roformerSW])
    }

    @Test func wrongBytesReportChecksum() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.override["BS-Roformer-SW.ckpt"] = Data(repeating: 9, count: 3_000)
        let library = f.library()
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(library.problems == [ModelLibrary.Problem(ids: [.roformerSW], failure: .checksum)])
        #expect(library.installed.isEmpty)
    }

    @Test func goneSourceReportsUnavailable() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.failure["htdemucs.safetensors"] = ModelFetchError.unavailable(status: 404)
        let library = f.library()
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(library.problems == [ModelLibrary.Problem(ids: [.htdemucs], failure: .unavailable)])
    }

    @Test func oversizedDownloadReportsChecksum() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.failure["htdemucs.safetensors"] = ModelFetchError.tooLarge
        let library = f.library()
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(library.problems == [ModelLibrary.Problem(ids: [.htdemucs], failure: .checksum)])
    }

    @Test func droppedConnectionReportsNetworkAndKeepsVerifiedModels() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.failure["BS-Roformer-SW.ckpt"] = ModelFetchError.network
        let library = f.library()
        library.requestDownload([.htdemucs, .roformerSW])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(library.problems == [ModelLibrary.Problem(ids: [.htdemucs, .roformerSW], failure: .network)])
        #expect(library.installed == [.htdemucs])
    }

    @Test func newRequestClearsTheOldProblem() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.failure["htdemucs.safetensors"] = ModelFetchError.network
        let library = f.library()
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(!library.problems.isEmpty)
        library.requestDownload([.htdemucs])
        #expect(library.problems.isEmpty)
        #expect(library.notice == [.htdemucs])
    }

    /// Waits until `condition` holds, for at most 3 s.
    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func secondDownloadIsQueuedAndRunsAfterTheFirst() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.held = ["htdemucs.safetensors"]
        let library = f.library()
        var notified = 0
        library.onInstalled = { notified += 1 }
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        library.requestDownload([.roformerSW])
        #expect(library.notice == [.roformerSW])
        library.confirmDownload()
        #expect(library.download?.ids == [.htdemucs, .roformerSW])
        #expect(library.download?.total == 4_502)
        f.fetcher.release("htdemucs.safetensors")
        await library.waitForDownload()
        #expect(library.installed == [.htdemucs, .roformerSW])
        #expect(library.download == nil)
        #expect(notified == 2)
    }

    @Test func progressIsOverTheWholeQueue() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.held = ["htdemucs.safetensors", "BS-Roformer-SW.ckpt"]
        let library = f.library()
        var installedFirst: Set<ModelID> = []
        library.onInstalled = { installedFirst = library.installed }
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        f.fetcher.release("htdemucs.safetensors")
        await waitFor { library.installed.contains(.htdemucs) }
        // The Live's model is there while SW still waits: it can start.
        #expect(installedFirst == [.htdemucs])
        await waitFor { (library.download?.fraction ?? 0) >= 502.0 / 4_502 }
        #expect(library.download?.ids == [.roformerSW])
        #expect(abs((library.download?.fraction ?? 0) - 502.0 / 4_502) < 0.001)
        f.fetcher.release("BS-Roformer-SW.ckpt")
        await library.waitForDownload()
        #expect(library.installed == [.htdemucs, .roformerSW])
    }

    @Test func alreadyQueuedModelIsNotAskedAgain() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.held = ["htdemucs.safetensors"]
        let library = f.library()
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        library.requestDownload([.htdemucs])
        #expect(library.notice == nil)
        library.cancelDownload()
        await library.waitForDownload()
    }

    /// Cancel takes back what the download already put in place: the next Download starts from zero.
    @Test func cancelRemovesTheFilesAlreadyVerified() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.held = ["BS-Roformer-SW.yaml"]
        let library = f.library()
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await waitFor { f.fetcher.calls.withLock { $0.contains("BS-Roformer-SW.yaml") } }
        let ckpt = f.store.destination.appending(path: "roformer/BS-Roformer-SW.ckpt")
        #expect(FileManager.default.fileExists(atPath: ckpt.path))
        library.cancelDownload()
        f.fetcher.release("BS-Roformer-SW.yaml")
        await library.waitForDownload()
        #expect(!FileManager.default.fileExists(atPath: ckpt.path))
        #expect(library.missingBytes([.roformerSW]) == 4_000)
        f.fetcher.held = []
        f.fetcher.calls.withLock { $0 = [] }
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(f.fetcher.calls.withLock { $0 } == ["BS-Roformer-SW.ckpt", "BS-Roformer-SW.yaml"])
        #expect(library.installed == [.roformerSW])
    }

    /// An interruption is not a Cancel: what was verified stays, and Retry fetches only the rest.
    @Test func interruptionKeepsTheFilesAlreadyVerified() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.failure["BS-Roformer-SW.yaml"] = URLError(.notConnectedToInternet)
        let library = f.library()
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(library.problems.count == 1)
        #expect(library.missingBytes([.roformerSW]) == 1_000)
        f.fetcher.failure = [:]
        f.fetcher.calls.withLock { $0 = [] }
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await library.waitForDownload()
        #expect(f.fetcher.calls.withLock { $0 } == ["BS-Roformer-SW.yaml"])
        #expect(library.installed == [.roformerSW])
    }

    @Test func cancelStopsTheWholeQueue() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.held = ["htdemucs.safetensors"]
        let library = f.library()
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        await waitFor { f.fetcher.calls.withLock { !$0.isEmpty } }
        library.cancelDownload()
        f.fetcher.release("htdemucs.safetensors")
        await library.waitForDownload()
        #expect(library.download == nil)
        #expect(library.installed.isEmpty)
        #expect(f.fetcher.calls.withLock { $0 } == ["htdemucs.safetensors"])
        #expect(f.downloads.isEmpty)
    }

    @Test func failedDownloadDoesNotStopTheNextInQueue() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.fetcher.held = ["htdemucs.safetensors"]
        f.fetcher.override["htdemucs.safetensors"] = Data(repeating: 9, count: 500)
        let library = f.library()
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        library.requestDownload([.roformerSW])
        library.confirmDownload()
        f.fetcher.release("htdemucs.safetensors")
        await library.waitForDownload()
        #expect(library.problems == [ModelLibrary.Problem(ids: [.htdemucs], failure: .checksum)])
        #expect(library.installed == [.roformerSW])
    }

    @Test func removeMakesTheModelMissing() throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("htdemucs.safetensors", in: "demucs")
        try f.put("htdemucs_config.json", in: "demucs")
        let library = f.library()
        library.remove(.htdemucs)
        #expect(library.installed.isEmpty)
        #expect(library.missingBytes([.htdemucs]) == 502)
    }

    @Test func importRejectsUnknownFile() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let stray = f.root.appending(path: "stray.ckpt")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: stray)
        let library = f.library()
        await library.importFile(stray)
        #expect(library.imported == .failed(.notInCatalog))
        #expect(library.installed.isEmpty)
    }

    @Test func importOfTheLastFileInstallsTheModel() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("BS-Roformer-SW.yaml", in: "roformer")
        let picked = f.root.appending(path: "picked.ckpt")
        try ModelLibraryTests.contents["BS-Roformer-SW.ckpt"]!.write(to: picked)
        let library = f.library()
        var notified = 0
        library.onInstalled = { notified += 1 }
        await library.importFile(picked)
        #expect(library.imported == .added(.roformerSW))
        #expect(library.installed == [.roformerSW])
        #expect(notified == 1)
    }

    /// "Added …" speaks of the last import: removing or downloading a model makes it stale, so it goes.
    @Test func importMessageGoesWhenModelsChange() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try f.put("BS-Roformer-SW.yaml", in: "roformer")
        let picked = f.root.appending(path: "picked.ckpt")
        try ModelLibraryTests.contents["BS-Roformer-SW.ckpt"]!.write(to: picked)
        let library = f.library()
        await library.importFile(picked)
        #expect(library.imported == .added(.roformerSW))
        library.remove(.roformerSW)
        #expect(library.imported == nil)

        await library.importFile(picked)
        #expect(library.imported == .added(.roformerSW))
        library.requestDownload([.htdemucs])
        library.confirmDownload()
        #expect(library.imported == nil)
        await library.waitForDownload()
    }
}
