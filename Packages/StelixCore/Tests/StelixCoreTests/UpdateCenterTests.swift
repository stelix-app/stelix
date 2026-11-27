// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import StelixCore

@MainActor struct UpdateCenterTests {
    nonisolated static let twoDays: TimeInterval = 2 * 24 * 3600
    nonisolated static let dmgBytes = Data(repeating: 7, count: 4_096)
    nonisolated static var dmgDigest: String { SHA256.hash(data: dmgBytes).map { String(format: "%02x", $0) }.joined() }

    nonisolated static func release(_ tag: String, digest: String? = dmgDigest, size: Int = dmgBytes.count) -> Data {
        let asset: [String: Any] = [
            "name": "Stelix-\(tag).dmg", "size": size, "digest": digest.map { "sha256:" + $0 } ?? NSNull(),
            "browser_download_url": "https://github.com/someone/Stelix/releases/download/\(tag)/Stelix.dmg",
        ]
        let object: [String: Any] = [
            "tag_name": tag, "draft": false, "prerelease": false, "assets": [asset],
            "html_url": "https://github.com/someone/Stelix/releases/tag/\(tag)", "published_at": "2026-12-02T10:30:00Z",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    final class Source: ReleaseSource, @unchecked Sendable {
        let answer = Mutex<Result<Data?, any Error>>(.success(nil))
        let calls = Mutex(0)
        /// While true the answer waits, as a slow GitHub would.
        let hold = Mutex(false)
        func latest() async throws -> Data? {
            calls.withLock { $0 += 1 }
            while hold.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
            return try answer.withLock { $0 }.get()
        }
        func set(_ data: Data?) { answer.withLock { $0 = .success(data) } }
        func fail() { answer.withLock { $0 = .failure(URLError(.notConnectedToInternet)) } }
    }

    final class Fetcher: ModelFetcher, @unchecked Sendable {
        let bytes = Mutex(UpdateCenterTests.dmgBytes)
        let failure = Mutex<(any Error)?>(nil)
        let hang = Mutex(false)
        /// While true a finished fetch does not return yet: the file is already written.
        let holdAfterWrite = Mutex(false)
        let started = AsyncStream<Void>.makeStream()
        func fetch(_ url: URL, expectedSize: Int64, to destination: URL,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
            started.continuation.yield()
            if hang.withLock({ $0 }) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: destination)
                while true { try await Task.sleep(for: .milliseconds(5)) }
            }
            if let failure = failure.withLock({ $0 }) { throw failure }
            let data = bytes.withLock { $0 }
            try data.write(to: destination)
            progress(Int64(data.count))
            while holdAfterWrite.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        }
    }

    final class Verifier: DiskImageVerifying, @unchecked Sendable {
        let failure = Mutex<DiskImageCheckError?>(nil)
        let checked = Mutex<[AppVersion]>([])
        /// How many of the next checks wait for `released`, which a Cancel does not stop, as with hdiutil.
        let held = Mutex(0)
        let released = Mutex(false)
        let finished = Mutex(0)
        func verify(_ dmg: URL, version: AppVersion) async throws {
            #expect(FileManager.default.fileExists(atPath: dmg.path))
            checked.withLock { $0.append(version) }
            let wait = held.withLock { count -> Bool in
                guard count > 0 else { return false }
                count -= 1
                return true
            }
            if wait {
                await Task.detached { [self] in
                    while !self.released.withLock({ $0 }) { usleep(1_000) }
                }.value
            }
            finished.withLock { $0 += 1 }
            if let failure = failure.withLock({ $0 }) { throw failure }
        }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    let source = Source()
    let fetcher = Fetcher()
    let verifier = Verifier()
    let clock = Clock()
    let defaults: UserDefaults
    let suite = "UpdateCenterTests-\(UUID().uuidString)"
    let root: URL

    init() {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appending(path: suite)
    }

    var downloads: URL { root.appending(path: "Downloads") }
    var work: URL { root.appending(path: "Work") }

    func make(_ current: String = "1.0") -> UpdateCenter {
        UpdateCenter(current: AppVersion(current)!, source: source, fetcher: fetcher, verifier: verifier,
                     defaults: defaults, downloads: downloads, work: work, now: { [clock] in clock.now })
    }

    func files(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
    }

    // MARK: - Checking

    @Test func checksAtMostOnceADay() async {
        source.set(Self.release("v1.0"))
        let center = make()
        await center.checkIfDue()
        await center.checkIfDue()
        #expect(source.calls.withLock { $0 } == 1)
        clock.now += 23 * 3600
        await center.checkIfDue()
        #expect(source.calls.withLock { $0 } == 1)
        clock.now += 2 * 3600
        await center.checkIfDue()
        #expect(source.calls.withLock { $0 } == 2)
        // The day counts across launches.
        await make().checkIfDue()
        #expect(source.calls.withLock { $0 } == 2)
    }

    /// A clock once set ahead must not stop the checks until that date.
    @Test func aLastCheckInTheFutureIsDue() async {
        defaults.set(clock.now.addingTimeInterval(365 * 24 * 3600), forKey: UpdateCenter.lastCheckKey)
        source.set(Self.release("v1.0"))
        await make().checkIfDue()
        #expect(source.calls.withLock { $0 } == 1)
    }

    /// Check Now while the automatic check waits for GitHub: Checking… at once, then the outcome of
    /// that same answer, with one request.
    @Test func checkNowDuringTheAutomaticCheckSaysHowItWent() async {
        source.set(Self.release("v1.0"))
        source.hold.withLock { $0 = true }
        let center = make()
        let automatic = Task { await center.checkIfDue() }
        for _ in 0..<400 where source.calls.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let manual = Task { await center.checkNow() }
        for _ in 0..<400 where center.check != .checking { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(center.check == .checking)
        source.hold.withLock { $0 = false }
        await automatic.value
        await manual.value
        #expect(center.check == .upToDate)
        #expect(source.calls.withLock { $0 } == 1)
    }

    @Test func checkNowDuringTheAutomaticCheckWaitsForTheVersion() async {
        source.set(Self.release("v1.1"))
        source.hold.withLock { $0 = true }
        let center = make()
        let automatic = Task { await center.checkIfDue() }
        for _ in 0..<400 where source.calls.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let manual = Task { await center.checkNow() }
        try? await Task.sleep(for: .milliseconds(20))
        source.hold.withLock { $0 = false }
        await manual.value
        // Check Now's answer is the automatic check's: the version is there when it returns.
        #expect(center.available?.version == AppVersion("1.1"))
        await automatic.value
    }

    @Test func automaticOffNeverChecksButCheckNowDoes() async {
        source.set(Self.release("v1.1"))
        let center = make()
        center.automatic = false
        #expect(make().automatic == false)
        await center.checkIfDue()
        #expect(source.calls.withLock { $0 } == 0)
        #expect(center.available == nil)
        await center.checkNow()
        #expect(center.available?.version == AppVersion("1.1"))
    }

    @Test func automaticIsOnByDefault() {
        #expect(make().automatic)
    }

    @Test func offersOnlyANewerVersion() async {
        let center = make("1.1")
        for tag in ["v1.0", "v1.1", "1.1.0"] {
            source.set(Self.release(tag))
            await center.checkNow()
            #expect(center.available == nil, "\(tag)")
            #expect(center.check == .upToDate)
        }
        source.set(Self.release("v1.1.1"))
        await center.checkNow()
        #expect(center.available?.version == AppVersion("1.1.1"))
        #expect(center.showsDot)
        #expect(center.stage == .offer)
        #expect(center.check == .idle)
    }

    @Test func noReleaseYetIsUpToDate() async {
        source.set(nil)
        let center = make()
        await center.checkNow()
        #expect(center.available == nil)
        #expect(center.check == .upToDate)
    }

    @Test func aFailedCheckIsRetriedAndOnlyCheckNowSaysSo() async {
        source.fail()
        let center = make()
        await center.checkIfDue()
        #expect(center.check == .idle)
        await center.checkIfDue()
        #expect(source.calls.withLock { $0 } == 2)
        await center.checkNow()
        #expect(center.check == .failed)
        source.set(Self.release("v1.1"))
        await center.checkNow()
        #expect(center.available != nil)
        #expect(center.check == .idle)
    }

    @Test func aMalformedAnswerIsAFailedCheck() async {
        source.set(Data("<html>rate limited</html>".utf8))
        let center = make()
        await center.checkNow()
        #expect(center.check == .failed)
        #expect(center.available == nil)
    }

    // MARK: - Later and Skip This Version

    @Test func skipHidesUntilTheNextVersion() async {
        source.set(Self.release("v1.1"))
        let center = make()
        await center.checkNow()
        center.skip()
        #expect(!center.showsDot)
        #expect(center.stage == .offer)
        // Remembered across launches, and long after.
        let again = make()
        await again.checkIfDue()
        clock.now += 30 * 24 * 3600
        await again.checkIfDue()
        #expect(again.available != nil)
        #expect(!again.showsDot)
        source.set(Self.release("v1.2"))
        clock.now += 25 * 3600
        await again.checkIfDue()
        #expect(again.showsDot)
    }

    @Test func laterHidesForTwoDays() async {
        source.set(Self.release("v1.1"))
        let center = make()
        await center.checkNow()
        center.later()
        #expect(!center.showsDot)
        // A day and more: the daily check finds the same version, still put off.
        clock.now += 47 * 3600
        await center.checkIfDue()
        #expect(!center.showsDot)
        // Remembered across launches, Check Now included.
        let again = make()
        await again.checkNow()
        #expect(!again.showsDot)
        again.later()
        clock.now += Self.twoDays - 60
        await again.checkIfDue()
        #expect(!again.showsDot)
        // Two days after this press: the hourly call brings it back, without asking GitHub
        // (the last answer is a minute old).
        let calls = source.calls.withLock { $0 }
        clock.now += 120
        await again.checkIfDue()
        #expect(again.showsDot)
        #expect(source.calls.withLock { $0 } == calls)
    }

    @Test func laterEachTimeStartsTwoDaysAgain() async {
        source.set(Self.release("v1.1"))
        let center = make()
        await center.checkNow()
        center.later()
        clock.now += Self.twoDays + 60
        await center.checkIfDue()
        #expect(center.showsDot)
        center.later()
        clock.now += Self.twoDays - 60
        await center.checkIfDue()
        #expect(!center.showsDot)
    }

    @Test func laterDoesNotHideANewerVersion() async {
        source.set(Self.release("v1.1"))
        let center = make()
        await center.checkNow()
        center.later()
        source.set(Self.release("v1.2"))
        clock.now += 25 * 3600
        await center.checkIfDue()
        #expect(center.showsDot)
        #expect(center.available?.version == AppVersion("1.2"))
    }

    @Test func checkNowLeavesAPutOffVersionPutOff() async {
        source.set(Self.release("v1.1"))
        let center = make()
        await center.checkNow()
        center.skip()
        await center.checkNow()
        #expect(!center.showsDot)
        #expect(center.available?.version == AppVersion("1.1"))
    }

    @Test func theNewestVersionAlwaysReplacesTheOneShown() async {
        source.set(Self.release("v1.1", size: 4_096))
        let center = make()
        await center.checkNow()
        center.skip()
        for (tag, size) in [("v1.2", 5_000), ("v1.3", 6_000)] {
            source.set(Self.release(tag, size: size))
            clock.now += 25 * 3600
            await center.checkIfDue()
            #expect(center.available?.version == AppVersion(tag))
            #expect(center.available?.dmg.size == Int64(size), "the size GitHub gives for this file")
            #expect(center.showsDot)
        }
        #expect(center.stage == .offer)
    }

    // MARK: - Window

    /// What `present` was asked, in order.
    final class Presented {
        var calls: [UpdateCenter.Presentation] = []
    }

    func watched(_ center: UpdateCenter) -> Presented {
        let presented = Presented()
        center.present = { presented.calls.append($0) }
        return presented
    }

    @Test func aNewVersionOpensTheWindowOnce() async {
        source.set(Self.release("v1.1"))
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        #expect(presented.calls == [.automatic])
        clock.now += 25 * 3600
        await center.checkIfDue()
        #expect(source.calls.withLock { $0 } == 2)
        #expect(presented.calls == [.automatic], "the same version, still on screen or closed by hand")
    }

    @Test func nothingNewOpensNothing() async {
        source.set(Self.release("v1.0"))
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        await center.checkNow()
        #expect(presented.calls == [])
    }

    @Test func aPutOffVersionDoesNotOpenIt() async {
        source.set(Self.release("v1.1"))
        let first = make()
        await first.checkIfDue()
        first.skip()
        clock.now += 25 * 3600
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        #expect(center.available?.version == AppVersion("1.1"))
        #expect(presented.calls == [])
    }

    /// The hourly call after Later's two days: once, not every hour after.
    @Test func laterReopensOnceWhenTheTwoDaysEnd() async {
        source.set(Self.release("v1.1"))
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        center.later()
        clock.now += Self.twoDays + 60
        for _ in 0..<3 {
            await center.checkIfDue()
            clock.now += 3600
        }
        #expect(presented.calls == [.automatic, .automatic])
    }

    @Test func aNewerVersionOpensItAgain() async {
        source.set(Self.release("v1.1"))
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        source.set(Self.release("v1.2"))
        clock.now += 25 * 3600
        await center.checkIfDue()
        #expect(presented.calls == [.automatic, .automatic])
        #expect(center.available?.version == AppVersion("1.2"))
    }

    @Test func checkNowOpensItAsRequested() async {
        source.set(Self.release("v1.1"))
        let center = make()
        let presented = watched(center)
        await center.checkNow()
        await center.checkNow()
        #expect(presented.calls == [.requested, .requested])
        center.skip()
        await center.checkNow()
        #expect(presented.calls == [.requested, .requested], "skipped: only the line in Settings")
    }

    @Test func openWindowWorksEvenWhenPutOff() async {
        source.set(Self.release("v1.1"))
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        center.skip()
        center.openWindow()
        #expect(presented.calls == [.automatic, .requested])
        #expect(center.putOff)
        #expect(make().isPutOff(AppVersion("1.1")!))
    }

    @Test func openWindowWithoutAVersionDoesNothing() {
        let center = make()
        let presented = watched(center)
        center.openWindow()
        #expect(presented.calls == [])
    }

    @Test func closingIsLater() async {
        source.set(Self.release("v1.1"))
        let center = make()
        let presented = watched(center)
        await center.checkIfDue()
        center.windowClosed()
        #expect(center.putOff)
        #expect(!center.showsDot)
        clock.now += Self.twoDays + 60
        await center.checkIfDue()
        #expect(center.showsDot)
        #expect(presented.calls == [.automatic, .automatic])
    }

    @Test func closingDuringADownloadLeavesIt() async {
        let center = await offered()
        let presented = watched(center)
        fetcher.hang.withLock { $0 = true }
        center.confirmDownload()
        center.windowClosed()
        #expect(center.stage == .downloading(fraction: 0))
        #expect(!center.putOff)
        center.openWindow()
        #expect(presented.calls == [.requested])
        center.cancelDownload()
    }

    @Test func closingWithTheDMGReadyLeavesIt() async {
        let center = await offered()
        center.confirmDownload()
        await finish(center)
        center.windowClosed()
        #expect(center.stage == .ready(downloads.appending(path: "Stelix-1.1.dmg")))
        #expect(!center.putOff)
    }

    @Test func closingAfterAFailureForgetsIt() async {
        fetcher.failure.withLock { $0 = ModelFetchError.network }
        let center = await offered()
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.network))
        center.windowClosed()
        #expect(center.stage == .offer)
        #expect(center.putOff)
    }

    @Test func noWindowDuringADownload() async {
        let center = await offered()
        let presented = watched(center)
        fetcher.hang.withLock { $0 = true }
        center.confirmDownload()
        source.set(Self.release("v1.2"))
        clock.now += 25 * 3600
        await center.checkIfDue()
        #expect(presented.calls == [])
        #expect(center.available?.version == AppVersion("1.1"))
        center.cancelDownload()
    }

    // MARK: - Download

    private func offered(_ tag: String = "v1.1", digest: String? = dmgDigest) async -> UpdateCenter {
        source.set(Self.release(tag, digest: digest))
        let center = make()
        await center.checkNow()
        return center
    }

    private func finish(_ center: UpdateCenter) async {
        for _ in 0..<500 {
            switch center.stage {
            case .downloading, .verifying: try? await Task.sleep(for: .milliseconds(5))
            default: return
            }
        }
    }

    @Test func laterAndSkipResetTheStage() async {
        let center = await offered()
        center.later()
        #expect(center.stage == .offer)
        #expect(!center.showsDot)
    }

    @Test func aVerifiedDownloadLandsInDownloads() async {
        let center = await offered()
        center.confirmDownload()
        await finish(center)
        let dmg = downloads.appending(path: "Stelix-1.1.dmg")
        #expect(center.stage == .ready(dmg))
        #expect(FileManager.default.contents(atPath: dmg.path) == Self.dmgBytes)
        #expect(verifier.checked.withLock { $0 } == [AppVersion("1.1")!])
        #expect(files(work).isEmpty)
    }

    @Test func aFileWithTheSameNameIsKept() async throws {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: downloads.appending(path: "Stelix-1.1.dmg"))
        try Data("mine too".utf8).write(to: downloads.appending(path: "Stelix-1.1 2.dmg"))
        let center = await offered()
        center.confirmDownload()
        await finish(center)
        let new = downloads.appending(path: "Stelix-1.1 3.dmg")
        #expect(center.stage == .ready(new))
        #expect(FileManager.default.contents(atPath: new.path) == Self.dmgBytes)
        #expect(FileManager.default.contents(atPath: downloads.appending(path: "Stelix-1.1.dmg").path) == Data("mine".utf8))
    }

    @Test func withoutDigestTheSignatureStillDecides() async {
        let center = await offered(digest: nil)
        center.confirmDownload()
        await finish(center)
        if case .ready = center.stage {} else { Issue.record("\(center.stage)") }
        #expect(verifier.checked.withLock { $0.count } == 1)
    }

    @Test func aWrongDigestDeletesTheFile() async {
        let center = await offered(digest: String(repeating: "0", count: 64))
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.checksum))
        #expect(verifier.checked.withLock { $0.isEmpty })
        #expect(files(downloads).isEmpty)
        #expect(files(work).isEmpty)
    }

    @Test func aWrongSizeIsAWrongFile() async {
        fetcher.bytes.withLock { $0 = Data(repeating: 7, count: 100) }
        let center = await offered(digest: nil)
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.checksum))
        #expect(files(downloads).isEmpty)
    }

    @Test func aFailedSignatureCheckDeletesTheFile() async {
        verifier.failure.withLock { $0 = .signature }
        let center = await offered()
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.verification))
        #expect(files(downloads).isEmpty)
        #expect(files(work).isEmpty)
    }

    @Test func withoutAVerifierNothingIsKept() async {
        source.set(Self.release("v1.1"))
        let center = UpdateCenter(current: AppVersion("1.0")!, source: source, fetcher: fetcher, verifier: nil,
                                  defaults: defaults, downloads: downloads, work: work, now: { [clock] in clock.now })
        await center.checkNow()
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.verification))
        #expect(files(downloads).isEmpty)
    }

    @Test func networkErrorsCanBeRetried() async {
        fetcher.failure.withLock { $0 = ModelFetchError.network }
        let center = await offered()
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.network))
        fetcher.failure.withLock { $0 = ModelFetchError.unavailable(status: 404) }
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .failed(.unavailable))
        fetcher.failure.withLock { $0 = nil }
        center.confirmDownload()
        await finish(center)
        if case .ready = center.stage {} else { Issue.record("\(center.stage)") }
    }

    @Test func cancelLeavesNothingBehind() async {
        fetcher.hang.withLock { $0 = true }
        let center = await offered()
        center.confirmDownload()
        var started = fetcher.started.stream.makeAsyncIterator()
        _ = await started.next()
        try? await Task.sleep(for: .milliseconds(20))
        center.cancelDownload()
        #expect(center.stage == .offer)
        for _ in 0..<100 where !files(work).isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(files(work).isEmpty)
        #expect(files(downloads).isEmpty)
        #expect(center.stage == .offer)
    }

    /// Cancel while the signature is checked (hdiutil does not stop), then Download again: the old check,
    /// when it returns, must not delete the file of the new download.
    @Test func aCancelledCheckLeavesTheNextDownloadAlone() async {
        verifier.held.withLock { $0 = 1 }
        let center = await offered()
        center.confirmDownload()
        for _ in 0..<400 where center.stage != .verifying { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(center.stage == .verifying)
        center.cancelDownload()
        fetcher.holdAfterWrite.withLock { $0 = true }
        center.confirmDownload()
        var started = fetcher.started.stream.makeAsyncIterator()
        _ = await started.next()
        _ = await started.next()
        try? await Task.sleep(for: .milliseconds(20))
        verifier.released.withLock { $0 = true }
        for _ in 0..<400 where verifier.finished.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        fetcher.holdAfterWrite.withLock { $0 = false }
        await finish(center)
        #expect(center.stage == .ready(downloads.appending(path: "Stelix-1.1.dmg")))
        #expect(files(work).isEmpty)
    }

    @Test func aCheckDuringTheDownloadDoesNotStopIt() async {
        let center = await offered()
        fetcher.hang.withLock { $0 = true }
        center.confirmDownload()
        source.set(Self.release("v1.2"))
        await center.checkNow()
        if case .downloading = center.stage {} else { Issue.record("\(center.stage)") }
        #expect(center.available?.version == AppVersion("1.1"))
        center.cancelDownload()
    }

    @Test func clearLeftoversEmptiesTheWorkFolder() throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data([1]).write(to: work.appending(path: "x.partial"))
        make().clearLeftovers()
        #expect(files(work).isEmpty)
    }

    @Test func theNameComesFromTheVersionNotFromGitHub() async {
        source.set(Self.release("v1.1").replacing(Data("Stelix-v1.1.dmg".utf8), with: Data("../../evil.dmg".utf8)))
        let center = make()
        await center.checkNow()
        center.confirmDownload()
        await finish(center)
        #expect(center.stage == .ready(downloads.appending(path: "Stelix-1.1.dmg")))
        #expect(files(root) == ["Downloads", "Work"])
    }
}
