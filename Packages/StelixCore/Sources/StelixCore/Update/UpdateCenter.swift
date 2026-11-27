// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Observation

/// Where the latest release comes from. Lives only in the app (`URLSessionReleaseSource`).
public protocol ReleaseSource: Sendable {
    /// The JSON of the latest release, or nil when the repository has none yet (404).
    func latest() async throws -> Data?
}

/// "Update available": at most one look a day at the repository's latest release (or now, with
/// Check Now), the update window while there's a newer version, and its download. The window opens
/// by itself once for each version found (`present`), and again when Later's two days are over;
/// Later, Skip This Version or its close button put it off. "Stelix 1.1 available" in Settings
/// opens it whatever was put off. The DMG arrives in a
/// work folder, must match GitHub's digest when there is one and pass `DiskImageVerifying` (same
/// certificate, same version), and only then moves to Downloads, where the user opens it and drags
/// the app to Applications. Stelix never replaces itself.
///
/// No network here: the source and the fetcher come from the app.
@MainActor @Observable public final class UpdateCenter {
    public enum Failure: Equatable, Sendable {
        /// The connection dropped or there is none.
        case network
        /// GitHub no longer serves the file.
        case unavailable
        /// The bytes aren't the ones GitHub announced: deleted.
        case checksum
        /// The app inside isn't signed like this one, or isn't the announced version: deleted.
        case verification
        /// Can't write in Downloads.
        case write
    }

    public enum Stage: Equatable, Sendable {
        /// Nothing under way: the notes, Skip This Version, Later and Download.
        case offer
        case downloading(fraction: Double)
        /// Digest and signature.
        case verifying
        /// The verified DMG, in Downloads.
        case ready(URL)
        case failed(Failure)
    }

    /// The outcome of Check Now, for the line in Settings. Automatic checks leave it alone.
    public enum Check: Equatable, Sendable {
        case idle, checking, upToDate, failed
    }

    /// How the window opens: by itself without taking the keyboard from the app in use, or after a
    /// click in Settings (or Check Now), in front and active.
    public enum Presentation: Equatable, Sendable {
        case automatic, requested
    }

    public static let interval: TimeInterval = 24 * 3600
    /// How long Later hides a version: two days from each press.
    public static let laterInterval: TimeInterval = 2 * 24 * 3600
    static let automaticKey = "updates.automatic"
    static let lastCheckKey = "updates.lastCheck"
    static let skippedKey = "updates.skippedVersion"
    static let laterVersionKey = "updates.laterVersion"
    static let laterUntilKey = "updates.laterUntil"

    public let current: AppVersion
    public private(set) var available: AvailableUpdate?
    public private(set) var stage: Stage = .offer
    public private(set) var check: Check = .idle
    /// Later (for two days), Skip This Version or the close button on the available version: the
    /// window does not open by itself and the menu bar icon has no dot.
    public private(set) var putOff = false

    /// Opens the update window. Set by the app.
    @ObservationIgnored public var present: ((Presentation) -> Void)?

    /// The toggle in Settings. On by default.
    public var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }

    /// The dot on the menu bar icon: a newer version the user hasn't put off.
    public var showsDot: Bool { available != nil && !putOff }

    @ObservationIgnored private let source: any ReleaseSource
    @ObservationIgnored private let fetcher: any ModelFetcher
    @ObservationIgnored private let verifier: (any DiskImageVerifying)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let downloads: URL
    @ObservationIgnored private let work: URL
    @ObservationIgnored private let allowLoopback: Bool
    /// The first part of the DMG's name in Downloads ("Stelix-1.1.dmg").
    @ObservationIgnored private let appName: String
    @ObservationIgnored private let now: () -> Date
    /// The request to GitHub under way: a second check waits for its answer instead of asking again.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Check Now was pressed during this request: Settings shows how it went.
    @ObservationIgnored private var reportOutcome = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every download and every Cancel: what an older one reports is ignored.
    @ObservationIgnored private var generation = 0
    /// The version the window last opened for by itself: the daily check finding it again leaves
    /// the window alone. Putting it off forgets it, so it opens again when Later is over.
    @ObservationIgnored private var announced: AppVersion?

    public init(current: AppVersion, source: any ReleaseSource, fetcher: any ModelFetcher,
                verifier: (any DiskImageVerifying)?, defaults: UserDefaults, downloads: URL, work: URL,
                appName: String = "Stelix", allowLoopback: Bool = false, now: @escaping () -> Date = Date.init) {
        self.appName = appName
        self.current = current
        self.source = source
        self.fetcher = fetcher
        self.verifier = verifier
        self.defaults = defaults
        self.downloads = downloads
        self.work = work
        self.allowLoopback = allowLoopback
        self.now = now
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// At launch: a download cut short by a crash or a quit.
    public func clearLeftovers() {
        guard task == nil else { return }
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Checking

    /// The automatic check: only with the toggle on, and only if a day has passed since the last
    /// one that got an answer. A failure is silent and retried at the next call. Called every
    /// hour, it also brings back a version whose two days of Later are over.
    public func checkIfDue() async {
        if let available { putOff = isPutOff(available.version) }
        defer { announce(manual: false) }
        guard automatic else { return }
        // A last check in the future (a clock that was ahead) is due: it would stop the checks until then.
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           case let elapsed = now().timeIntervalSince(last), elapsed >= 0, elapsed < Self.interval {
            return
        }
        await run(manual: false)
    }

    /// Check Now in Settings: asks at once and says how it went, and opens the window on a newer
    /// version. A version put off stays so: Settings shows it on its line.
    public func checkNow() async {
        await run(manual: true)
        announce(manual: true)
    }

    /// Opens the window on a newer version nobody put off and nothing is downloading: always after
    /// Check Now, otherwise once per version.
    private func announce(manual: Bool) {
        guard let available, !putOff, !busy else { return }
        if manual {
            present?(.requested)
        } else if announced != available.version {
            present?(.automatic)
        }
        announced = available.version
    }

    /// Settings opened again: the line goes back to Check Now.
    public func clearCheckOutcome() {
        if check != .checking { check = .idle }
    }

    /// Check Now during the automatic check shows Checking… at once and the outcome of that same answer.
    private func run(manual: Bool) async {
        if manual {
            reportOutcome = true
            check = .checking
        }
        if let inFlight {
            await inFlight.value
            return
        }
        let request = Task { await ask() }
        inFlight = request
        await request.value
        inFlight = nil
    }

    private func ask() async {
        do {
            let data = try await source.latest()
            let update = try data.flatMap { try GitHubRelease.parse($0, allowLoopback: allowLoopback) }
            defaults.set(now(), forKey: Self.lastCheckKey)
            apply(update)
            if reportOutcome {
                check = available == nil ? .upToDate : .idle
            }
        } catch {
            if reportOutcome { check = .failed }
        }
        reportOutcome = false
    }

    private func apply(_ update: AvailableUpdate?) {
        // A download already under way finishes with the version it started.
        if busy { return }
        guard let update, update.version > current else {
            available = nil
            stage = .offer
            return
        }
        if update.version != available?.version {
            stage = .offer
        }
        available = update
        putOff = isPutOff(update.version)
    }

    var busy: Bool {
        switch stage {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// Skipped, or put off with Later less than two days ago. Both bind to that version only.
    func isPutOff(_ version: AppVersion) -> Bool {
        if defaults.string(forKey: Self.skippedKey).flatMap(AppVersion.init) == version { return true }
        guard defaults.string(forKey: Self.laterVersionKey).flatMap(AppVersion.init) == version,
              let until = defaults.object(forKey: Self.laterUntilKey) as? Date
        else { return false }
        return now() < until
    }

    // MARK: - Window

    /// Later: put off for two days from now, each time. A newer version opens the window at once.
    public func later() {
        guard let available, !busy else { return }
        defaults.set(available.version.description, forKey: Self.laterVersionKey)
        defaults.set(now().addingTimeInterval(Self.laterInterval), forKey: Self.laterUntilKey)
        markPutOff()
    }

    /// Skip This Version: put off until a newer version.
    public func skip() {
        guard let available, !busy else { return }
        defaults.set(available.version.description, forKey: Self.skippedKey)
        markPutOff()
    }

    private func markPutOff() {
        putOff = true
        announced = nil
        stage = .offer
    }

    /// "Stelix 1.1 available" in Settings: the window, in front, even for a version put off.
    public func openWindow() {
        guard available != nil else { return }
        present?(.requested)
    }

    /// The window's close button: Later, and a failure is forgotten. A download under way, or one
    /// ready in Downloads, stays as it is: Settings brings the window back.
    public func windowClosed() {
        switch stage {
        case .offer, .failed: later()
        case .downloading, .verifying, .ready: break
        }
    }

    // MARK: - Download

    /// Download in the details, or Try Again after a failure.
    public func confirmDownload() {
        guard let update = available, !busy else { return }
        generation += 1
        let generation = generation
        stage = .downloading(fraction: 0)
        task = Task { [weak self] in
            await self?.download(update, generation: generation)
        }
    }

    public func cancelDownload() {
        guard busy else { return }
        generation += 1
        task?.cancel()
        task = nil
        stage = .offer
    }

    private func download(_ update: AvailableUpdate, generation: Int) async {
        let fm = FileManager.default
        // One file per download: a cancelled one whose check still runs (hdiutil does not stop) deletes
        // its own file when it returns, not the one the next download is writing.
        let partial = work.appending(path: "update-\(generation).dmg.partial")
        defer { try? fm.removeItem(at: partial) }
        let outcome: Stage
        do {
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
            } catch {
                throw Failure.write
            }
            let size = update.dmg.size
            try await fetcher.fetch(update.dmg.url, expectedSize: size, to: partial) { [weak self] bytes in
                Task { @MainActor in
                    guard let self, self.generation == generation, case .downloading = self.stage else { return }
                    self.stage = .downloading(fraction: min(Double(bytes) / Double(max(size, 1)), 1))
                }
            }
            try Task.checkCancellation()
            guard self.generation == generation else { return }
            stage = .verifying
            try await Self.checkBytes(partial, size: size, sha256: update.dmg.sha256)
            guard let verifier else { throw Failure.verification }
            do {
                try await verifier.verify(partial, version: update.version)
            } catch {
                throw Failure.verification
            }
            try Task.checkCancellation()
            let destination: URL
            do {
                try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
                destination = Self.freeName("\(appName)-\(update.version).dmg", in: downloads)
                try fm.moveItem(at: partial, to: destination)
            } catch {
                throw Failure.write
            }
            outcome = .ready(destination)
        } catch is CancellationError {
            return
        } catch let failure as Failure {
            outcome = .failed(failure)
        } catch ModelFetchError.unavailable {
            outcome = .failed(.unavailable)
        } catch ModelFetchError.tooLarge {
            outcome = .failed(.checksum)
        } catch ModelStoreError.write {
            outcome = .failed(.write)
        } catch {
            outcome = .failed(.network)
        }
        guard self.generation == generation else { return }
        task = nil
        stage = outcome
    }

    /// The size GitHub announced and, when it gives one, the SHA-256. Hashed off the main actor.
    private static func checkBytes(_ file: URL, size: Int64, sha256: String?) async throws {
        let ok = await Task.detached(priority: .utility) { () -> Bool in
            let actual = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            guard actual == size else { return false }
            guard let sha256 else { return true }
            return (try? FileDigest.sha256(of: file)) == sha256
        }.value
        guard ok else { throw Failure.checksum }
    }

    /// `name` in `folder`, or "Stelix-1.1 2.dmg", "Stelix-1.1 3.dmg"… as Finder does: a file already
    /// in Downloads is never replaced. The name comes from the verified version, not from GitHub.
    static func freeName(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while fm.fileExists(atPath: candidate.path) || (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            candidate = folder.appending(path: "\(stem) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

extension UpdateCenter.Failure: Error {}
