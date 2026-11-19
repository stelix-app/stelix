// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Observation

/// What the app knows about the models: which are installed, the notice open before a download,
/// the downloads in progress and how they ended. The unit of a download is what a level needs: the
/// panel asks for the level's models and only the missing ones are fetched. A request made while
/// another download runs (Live downloading, then Studio) joins a queue: files come one after the
/// other, with a single progress over every byte in the queue, and each level's models count as
/// installed as soon as they're verified, so the Live can start while the Studio's still arrive.
///
/// No network here: the fetcher comes from the app (`URLSessionFetcher`). Engine and sidecar never
/// see this class.
@MainActor @Observable public final class ModelLibrary {
    public enum Failure: Equatable, Sendable {
        /// The source no longer serves the file (404, 410…).
        case unavailable
        /// The connection dropped or there is none.
        case network
        /// The downloaded bytes aren't the catalog's: the file was deleted.
        case checksum
        /// Can't write in `Models/`.
        case write
        /// "Add Model…" with a file that isn't one of Stelix's.
        case notInCatalog
        /// The volume needs `needed` bytes free (what's missing plus 10%).
        case notEnoughSpace(needed: Int64)
    }

    /// The whole queue, as the bar and the menu bar icon show it.
    public struct Download: Equatable, Sendable {
        /// The models still to arrive, the one downloading first.
        public var ids: [ModelID]
        /// Every byte the queue had to download, finished requests included.
        public var total: Int64
        /// 0...1 over `total`.
        public var fraction: Double
    }

    /// How the last download of `ids` ended, when it didn't succeed.
    public struct Problem: Equatable, Sendable {
        public let ids: [ModelID]
        public let failure: Failure

        public init(ids: [ModelID], failure: Failure) {
            self.ids = ids
            self.failure = failure
        }
    }

    public enum ImportOutcome: Equatable, Sendable {
        case added(ModelID)
        case failed(Failure)
    }

    public let store: ModelStore
    public private(set) var installed: Set<ModelID> = []
    /// The models listed by the notice the user is reading, before Download.
    public private(set) var notice: [ModelID]?
    public private(set) var download: Download?
    /// How the requests that didn't succeed ended, one per request.
    public private(set) var problems: [Problem] = []
    /// "Add Model…" is checking a file.
    public private(set) var importing = false
    public private(set) var imported: ImportOutcome?
    /// Called on the main actor after a download or an import that completed a model.
    @ObservationIgnored public var onInstalled: (@MainActor () -> Void)?

    @ObservationIgnored private let installer: ModelInstaller
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped at every request that starts: progress from an older one is ignored.
    @ObservationIgnored private var generation = 0
    /// One confirmed notice: its models and the bytes they missed when it joined the queue.
    private struct Request {
        let ids: [ModelID]
        let total: Int64
    }
    /// Requests waiting behind the one downloading.
    @ObservationIgnored private var queue: [Request] = []
    /// Bytes of the requests already ended, out of `download.total`.
    @ObservationIgnored private var doneBytes: Int64 = 0
    @ObservationIgnored private var cancelled = false

    public convenience init(store: ModelStore, fetcher: any ModelFetcher) {
        self.init(installer: ModelInstaller(store: store, fetcher: fetcher))
    }

    init(installer: ModelInstaller) {
        self.installer = installer
        store = installer.store
        refresh()
    }

    /// At launch, before any download: what's in `.downloads` is a half file left by a crash or a
    /// kill. Only the real app calls it: a snapshot running beside it must not touch its download.
    public func clearLeftovers() {
        guard download == nil else { return }
        try? FileManager.default.removeItem(at: store.downloadsDirectory)
    }

    // MARK: - Reading

    /// The models among `ids` that aren't installed, in the order of `ids`.
    public func missing(_ ids: [ModelID]) -> [ModelID] {
        ids.filter { !installed.contains($0) }
    }

    /// What's left to download for `ids` ("Pro needs 639 MB").
    public func missingBytes(_ ids: [ModelID]) -> Int64 {
        _ = installed // observed: the size changes when a model arrives or goes
        return store.missingBytes(ids)
    }

    public func refresh() {
        let now = Set(store.catalog.packages.map(\.id).filter(store.isInstalled))
        if now != installed { installed = now }
    }

    // MARK: - Download

    /// Opens the notice for the models among `ids` that are missing and not already downloading or
    /// queued. Nothing opens when there's nothing left to ask for.
    public func requestDownload(_ ids: [ModelID]) {
        // While a Cancel empties the queue, a new request would be lost with it.
        guard !(cancelled && download != nil) else { return }
        let coming = Set(download?.ids ?? [])
        let missing = missing(ids).filter { !coming.contains($0) }
        guard !missing.isEmpty else { return }
        problems.removeAll { !Set($0.ids).isDisjoint(with: missing) }
        notice = missing
    }

    public func dismissNotice() {
        notice = nil
    }

    /// Download in the notice: its models join the queue, which starts if it was empty.
    public func confirmDownload() {
        guard let asked = notice else { return }
        notice = nil
        let coming = Set(download?.ids ?? [])
        let ids = missing(asked).filter { !coming.contains($0) }
        guard !ids.isEmpty else { return }
        imported = nil
        let request = Request(ids: ids, total: store.missingBytes(ids))
        queue.append(request)
        if var current = download {
            current.ids += ids
            current.total += request.total
            current.fraction = Double(doneBytes) / Double(max(current.total, 1))
            download = current
            return
        }
        cancelled = false
        doneBytes = 0
        download = Download(ids: ids, total: request.total, fraction: 0)
        task = Task { [weak self] in
            while let self, !self.cancelled, !self.queue.isEmpty {
                let request = self.queue.removeFirst()
                await self.run(request)
            }
            self?.endQueue()
        }
    }

    /// One request: its missing files one after the other, then installed, notified or failed.
    private func run(_ request: Request) async {
        generation += 1
        let generation = generation
        let installer = installer
        // Held only while the download runs.
        let report: @Sendable (Double) -> Void = { [self] fraction in
            Task { @MainActor in self.progressed(fraction, of: request.total, generation: generation) }
        }
        var outcome: Failure?
        do {
            try await installer.install(request.ids, progress: report)
        } catch is CancellationError {
            outcome = nil
        } catch {
            outcome = cancelled ? nil : Self.failure(for: error)
        }
        // Progress of this request still on its way must not count twice.
        self.generation += 1
        doneBytes += request.total
        refresh()
        if var current = download {
            current.ids.removeAll { request.ids.contains($0) }
            current.fraction = Double(doneBytes) / Double(max(current.total, 1))
            download = current
        }
        guard !cancelled else { return }
        if let outcome {
            problems.append(Problem(ids: request.ids, failure: outcome))
        } else if missing(request.ids).isEmpty {
            onInstalled?()
        }
    }

    private func endQueue() {
        queue = []
        download = nil
        task = nil
        doneBytes = 0
        refresh()
    }

    /// Cancel: stops the download, deletes the half-written file and the files the running request already
    /// put in place (`ModelInstaller.install`), and empties the queue. Requests that already ended stay installed.
    public func cancelDownload() {
        guard download != nil else { return }
        cancelled = true
        queue = []
        task?.cancel()
    }

    /// For tests: waits for the queue to end.
    func waitForDownload() async {
        await task?.value
    }

    private func progressed(_ fraction: Double, of requestTotal: Int64, generation: Int) {
        guard generation == self.generation, var current = download, current.total > 0 else { return }
        let bytes = Double(doneBytes) + min(max(fraction, 0), 1) * Double(requestTotal)
        let overall = min(bytes / Double(current.total), 1)
        guard overall > current.fraction else { return }
        current.fraction = overall
        download = current
    }

    // MARK: - Remove and import

    public func remove(_ id: ModelID) {
        imported = nil
        do {
            try store.remove(id)
            problems.removeAll { $0.ids.contains(id) }
        } catch {
            problems.append(Problem(ids: [id], failure: .write))
        }
        refresh()
    }

    /// "Add Model…": if the file is one of the catalog's, it's copied in place.
    public func importFile(_ url: URL) async {
        importing = true
        imported = nil
        let installer = installer
        let result: ImportOutcome = await Task.detached(priority: .userInitiated) {
            do {
                return .added(try installer.importFile(url))
            } catch {
                return .failed(Self.failure(for: error))
            }
        }.value
        importing = false
        imported = result
        refresh()
        if case .added(let id) = result, installed.contains(id) { onInstalled?() }
    }

    public func clearImported() {
        imported = nil
    }

    nonisolated static func failure(for error: any Error) -> Failure {
        switch error {
        case ModelFetchError.unavailable: .unavailable
        case ModelFetchError.network: .network
        case ModelFetchError.tooLarge: .checksum
        case ModelStoreError.checksumMismatch: .checksum
        case ModelStoreError.notInCatalog: .notInCatalog
        case ModelStoreError.notEnoughSpace(let needed): .notEnoughSpace(needed: needed)
        case is URLError: .network
        default: .write
        }
    }
}
