// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// Whoever downloads a file. Lives only in the app: engine and sidecar stay without network.
public protocol ModelFetcher: Sendable {
    /// Writes `url` to `destination`. `progress` receives the bytes written so far. An HTTP status
    /// other than 200 throws `ModelFetchError.unavailable(status:)`, a cancellation `CancellationError`.
    /// A URL or a redirect that `ModelFetchPolicy` does not allow is not followed (`unavailable`).
    /// More bytes than `expectedSize` throw `ModelFetchError.tooLarge` as soon as they arrive: a
    /// source that streams without end must not fill the disk before the SHA-256 check.
    func fetch(_ url: URL, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum ModelFetchError: Error, Equatable, Sendable {
    /// The source no longer serves the file (404, 410…).
    case unavailable(status: Int)
    /// The network is down or absent.
    case network
    /// The source sent more bytes than the catalog's size.
    case tooLarge
}

/// Where a model file may come from. The fingerprint already says whether the bytes are the right
/// ones; this keeps the request itself, and every redirect after it, on HTTPS.
public enum ModelFetchPolicy {
    public static func allows(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }
}

/// Downloads and installs the models, or imports one chosen by hand. Every file goes through
/// `store.downloadsDirectory` and reaches its place only if the fingerprint matches the catalog.
public struct ModelInstaller: Sendable {
    public let store: ModelStore
    public let fetcher: any ModelFetcher
    /// Free bytes on the `Models/` volume, nil if unknown.
    let availableSpace: @Sendable (URL) -> Int64?

    public init(store: ModelStore, fetcher: any ModelFetcher) {
        self.init(store: store, fetcher: fetcher, availableSpace: Self.volumeAvailableSpace)
    }

    init(store: ModelStore, fetcher: any ModelFetcher, availableSpace: @escaping @Sendable (URL) -> Int64?) {
        self.store = store
        self.fetcher = fetcher
        self.availableSpace = availableSpace
    }

    public func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await install([id], progress: progress)
    }

    /// Downloads, one after another, the files the models `ids` are missing. The 0...1 fraction is over the bytes
    /// of everything that is missing. If a file fails, those already verified stay installed, so Retry
    /// fetches only the rest; if the task is cancelled, the files this call put in place are removed
    /// and the next download starts from zero. Before starting there must be room for what is missing plus 10%.
    public func install(_ ids: [ModelID], progress: @escaping @Sendable (Double) -> Void) async throws {
        let files = store.missingFiles(ids)
        let total = files.reduce(0) { $0 + $1.size }
        guard total > 0 else {
            progress(1)
            return
        }
        let needed = total + total / 10
        if let free = availableSpace(store.destination), free < needed {
            throw ModelStoreError.notEnoughSpace(needed: needed)
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: store.downloadsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.write
        }
        var done: Int64 = 0
        var placed: [ModelFile] = []
        do {
            for file in files {
                try Task.checkCancellation()
                let temporary = store.downloadsDirectory.appending(path: file.name)
                try? fm.removeItem(at: temporary)
                let before = done
                do {
                    try await fetcher.fetch(file.url, expectedSize: file.size, to: temporary) { written in
                        progress(Double(before + min(written, file.size)) / Double(total))
                    }
                    try Task.checkCancellation()
                } catch {
                    try? fm.removeItem(at: temporary)
                    throw error
                }
                try store.install(file, from: temporary)
                placed.append(file)
                done += file.size
            }
        } catch {
            if Task.isCancelled {
                for file in placed { try? fm.removeItem(at: store.target(file)) }
            }
            throw error
        }
    }

    /// "Add Model…": if the fingerprint of `url` is that of a catalog file, it copies it (does not
    /// move it) and installs it under the catalog name. Returns the model it belongs to.
    public func importFile(_ url: URL) throws -> ModelID {
        let digest: String
        do {
            digest = try FileDigest.sha256(of: url)
        } catch {
            throw ModelStoreError.notInCatalog
        }
        guard let file = store.catalog.file(sha256: digest),
              let package = store.catalog.package(containing: file.name) else {
            throw ModelStoreError.notInCatalog
        }
        let fm = FileManager.default
        let temporary = store.downloadsDirectory.appending(path: "\(file.name).import")
        do {
            try fm.createDirectory(at: store.downloadsDirectory, withIntermediateDirectories: true)
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: url, to: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw ModelStoreError.write
        }
        try store.install(file, from: temporary)
        return package.id
    }

    /// `volumeAvailableCapacityForImportantUsage` of the first folder that exists going up from `url`.
    static let volumeAvailableSpace: @Sendable (URL) -> Int64? = { url in
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
