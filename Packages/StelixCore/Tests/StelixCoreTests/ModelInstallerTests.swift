// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import StelixCore

struct ModelInstallerTests {
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Fake file contents, chosen by the test: the catalog's fingerprint is theirs.
    private static let contents: [String: Data] = [
        "BS-Roformer-SW.ckpt": Data(repeating: 1, count: 3_000),
        "BS-Roformer-SW.yaml": Data(repeating: 2, count: 1_000),
        "htdemucs.safetensors": Data(repeating: 3, count: 500),
        "htdemucs_config.json": Data("{}".utf8),
    ]

    private static let catalog: ModelCatalog = {
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

    /// Writes the bytes of `contents` (or those of `override`) in 1000-byte pieces, calling `progress`
    /// after each piece. It can throw a chosen error or stop halfway until the task is cancelled.
    private final class FakeFetcher: ModelFetcher, @unchecked Sendable {
        let calls = Mutex<[String]>([])
        let sizes = Mutex<[String: Int64]>([:])
        var override: [String: Data] = [:]
        var failure: [String: any Error] = [:]
        /// For this file it writes the first piece, then waits for the cancellation.
        var hangOn: String?
        let started = AsyncStream<Void>.makeStream()

        func fetch(_ url: URL, expectedSize: Int64, to destination: URL,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
            let name = url.lastPathComponent
            calls.withLock { $0.append(name) }
            sizes.withLock { $0[name] = expectedSize }
            if let error = failure[name] { throw error }
            let data = override[name] ?? ModelInstallerTests.contents[name]!
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var written = 0
            while written < data.count {
                let chunk = data[written..<min(written + 1_000, data.count)]
                try handle.write(contentsOf: chunk)
                written += chunk.count
                progress(Int64(written))
                if name == hangOn {
                    started.continuation.yield()
                    try await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private struct Fixture {
        let root: URL
        let store: ModelStore
        init() {
            root = FileManager.default.temporaryDirectory.appending(path: "ModelInstallerTests-\(UUID().uuidString)")
            store = ModelStore(destination: root.appending(path: "Models"), sources: [], catalog: ModelInstallerTests.catalog)
        }
        func installer(_ fetcher: FakeFetcher, space: Int64? = nil) -> ModelInstaller {
            ModelInstaller(store: store, fetcher: fetcher, availableSpace: { _ in space })
        }
        var downloads: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: store.downloadsDirectory.path)) ?? []
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Fractions: @unchecked Sendable {
        let values = Mutex<[Double]>([])
        var all: [Double] { values.withLock { $0 } }
        func add(_ value: Double) { values.withLock { $0.append(value) } }
    }

    @Test func installsPackageAndReportsProgress() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fractions = Fractions()
        try await fx.installer(FakeFetcher()).install(.roformerSW) { fractions.add($0) }

        #expect(fx.store.isInstalled(.roformerSW))
        #expect(fx.downloads.isEmpty)
        let values = fractions.all
        #expect(values.count == 4)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(values.first == 0.25)
        #expect(values.last == 1)
    }

    /// A level that asks for two models: a single progress, over the total of what is missing.
    @Test func fetcherIsToldEachFileSize() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fetcher = FakeFetcher()
        try await fx.installer(fetcher).install(.roformerSW) { _ in }
        #expect(fetcher.sizes.withLock { $0 } == ["BS-Roformer-SW.ckpt": 3_000, "BS-Roformer-SW.yaml": 1_000])
    }

    @Test func installsSeveralWithOneProgress() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fractions = Fractions()
        let fetcher = FakeFetcher()
        try await fx.installer(fetcher).install([.htdemucs, .roformerSW]) { fractions.add($0) }

        #expect(fx.store.isInstalled(.htdemucs) && fx.store.isInstalled(.roformerSW))
        #expect(fetcher.calls.withLock { $0 } == ["htdemucs.safetensors", "htdemucs_config.json", "BS-Roformer-SW.ckpt", "BS-Roformer-SW.yaml"])
        let values = fractions.all
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1)
        #expect(fx.store.missingBytes([.htdemucs, .roformerSW]) == 0)
    }

    @Test func wrongBytesAreRejected() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fetcher = FakeFetcher()
        fetcher.override["BS-Roformer-SW.ckpt"] = Data(repeating: 9, count: 3_000)
        await #expect(throws: ModelStoreError.checksumMismatch(file: "BS-Roformer-SW.ckpt")) {
            try await fx.installer(fetcher).install(.roformerSW) { _ in }
        }
        #expect(!fx.store.isInstalled(.roformerSW))
        #expect(fx.downloads.isEmpty)
    }

    @Test func cancelledDownloadLeavesNothingInstalled() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fetcher = FakeFetcher()
        fetcher.hangOn = "BS-Roformer-SW.ckpt"
        let installer = fx.installer(fetcher)
        let task = Task { try await installer.install(.roformerSW) { _ in } }
        for await _ in fetcher.started.stream { break }
        #expect(fx.downloads == ["BS-Roformer-SW.ckpt"])
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(!fx.store.isInstalled(.roformerSW))
        #expect(fx.downloads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.store.roformerDirectory.appending(path: "BS-Roformer-SW.ckpt").path))

        // The new attempt starts clean.
        try await fx.installer(FakeFetcher()).install(.roformerSW) { _ in }
        #expect(fx.store.isInstalled(.roformerSW))
    }

    /// If the second model fails, the first, already verified, stays installed.
    @Test func failureKeepsModelsAlreadyVerified() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fetcher = FakeFetcher()
        fetcher.failure["BS-Roformer-SW.ckpt"] = ModelFetchError.network
        await #expect(throws: ModelFetchError.network) {
            try await fx.installer(fetcher).install([.htdemucs, .roformerSW]) { _ in }
        }
        #expect(fx.store.isInstalled(.htdemucs))
        #expect(!fx.store.isInstalled(.roformerSW))
        #expect(fx.downloads.isEmpty)
    }

    @Test func unavailableSourceSurfaces() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fetcher = FakeFetcher()
        fetcher.failure["BS-Roformer-SW.ckpt"] = ModelFetchError.unavailable(status: 404)
        await #expect(throws: ModelFetchError.unavailable(status: 404)) {
            try await fx.installer(fetcher).install(.roformerSW) { _ in }
        }
        #expect(fx.downloads.isEmpty)
    }

    @Test func skipsFilesAlreadyInstalled() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        try await fx.installer(FakeFetcher()).install(.roformerSW) { _ in }
        let fetcher = FakeFetcher()
        let fractions = Fractions()
        try await fx.installer(fetcher).install(.roformerSW) { fractions.add($0) }
        #expect(fetcher.calls.withLock { $0 }.isEmpty)
        #expect(fractions.all == [1])
    }

    /// It needs what is missing plus 10%: 4000 bytes of SW ask for 4400 free bytes.
    @Test func notEnoughSpaceFailsBeforeFetching() async throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let fetcher = FakeFetcher()
        await #expect(throws: ModelStoreError.notEnoughSpace(needed: 4_400)) {
            try await fx.installer(fetcher, space: 4_399).install(.roformerSW) { _ in }
        }
        #expect(fetcher.calls.withLock { $0 }.isEmpty)
        try await fx.installer(fetcher, space: 4_400).install(.roformerSW) { _ in }
        #expect(fx.store.isInstalled(.roformerSW))
    }

    @Test func importAcceptsCatalogFile() throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let picked = fx.root.appending(path: "scelto da me.ckpt")
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        try Self.contents["BS-Roformer-SW.ckpt"]!.write(to: picked)

        #expect(try fx.installer(FakeFetcher()).importFile(picked) == .roformerSW)
        // Copied under the catalog name, and the original stays where it was.
        #expect(FileManager.default.fileExists(atPath: fx.store.roformerDirectory.appending(path: "BS-Roformer-SW.ckpt").path))
        #expect(FileManager.default.fileExists(atPath: picked.path))
        #expect(fx.downloads.isEmpty)
    }

    @Test func importRejectsUnknownFile() throws {
        let fx = Fixture()
        defer { fx.cleanup() }
        let picked = fx.root.appending(path: "BS-Roformer-SW.ckpt")
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        var bytes = Self.contents["BS-Roformer-SW.ckpt"]!
        bytes[0] ^= 1
        try bytes.write(to: picked)

        #expect(throws: ModelStoreError.notInCatalog) { try fx.installer(FakeFetcher()).importFile(picked) }
        #expect(!FileManager.default.fileExists(atPath: fx.store.roformerDirectory.path))
        #expect(fx.downloads.isEmpty)
    }
}

struct ModelFetchPolicyTests {
    @Test(arguments: [
        "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/x.ckpt",
        "https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=abc",
        "HTTPS://huggingface.co/ssmall256/demucs-mlx/resolve/main/htdemucs.safetensors",
    ])
    func httpsIsAllowed(url: String) {
        #expect(ModelFetchPolicy.allows(URL(string: url)))
    }

    /// Plain HTTP is refused also where the system's own rule (App Transport Security) lets it
    /// through: IP addresses and local names.
    @Test(arguments: [
        "http://github.com/x.ckpt", "http://127.0.0.1:8000/x.ckpt", "http://10.0.0.5/x.ckpt", "http://localhost/x.ckpt",
        "http://nas.local/x.ckpt", "ftp://github.com/x.ckpt", "file:///tmp/x.ckpt", "github.com/x.ckpt", "data:text/plain,x",
    ])
    func everythingElseIsRefused(url: String) {
        #expect(!ModelFetchPolicy.allows(URL(string: url)))
    }

    @Test func noURLIsRefused() {
        #expect(!ModelFetchPolicy.allows(nil))
    }

    @Test func everyCatalogFileIsAllowed() {
        #expect(ModelCatalog.shipped.packages.flatMap(\.files).allSatisfy { ModelFetchPolicy.allows($0.url) })
    }
}
