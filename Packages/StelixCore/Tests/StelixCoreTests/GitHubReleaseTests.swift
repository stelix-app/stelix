// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct AppVersionTests {
    @Test func readsTagsWithOrWithoutV() {
        #expect(AppVersion("1.0")?.components == [1, 0])
        #expect(AppVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("V2")?.components == [2])
        #expect(AppVersion(" 1.1 ")?.components == [1, 1])
    }

    @Test func rejectsWhatIsNotAPlainVersion() {
        for text in ["", "v", "1.0-beta", "1..0", "1.0.", "abc", "1.-1", "1.0.0.0.0", "１.０"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumbersNotText() {
        #expect(AppVersion("1.10")! > AppVersion("1.9")!)
        #expect(AppVersion("1.0.1")! > AppVersion("1.0")!)
        #expect(AppVersion("2")! > AppVersion("1.99.99")!)
        #expect(!(AppVersion("1.0")! < AppVersion("1.0.0")!))
        #expect(!(AppVersion("1.0.0")! < AppVersion("1.0")!))
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
    }

    @Test func printsWithoutTheV() {
        #expect(AppVersion("v1.1")!.description == "1.1")
    }
}

struct GitHubReleaseTests {
    static let digest = String(repeating: "ab", count: 32)

    static func json(
        tag: String = "v1.1", draft: Bool = false, prerelease: Bool = false,
        html: String = "https://github.com/someone/Stelix/releases/tag/v1.1",
        assets: [(name: String, url: String, size: Int, digest: String?)] = [
            ("Stelix-1.1.dmg", "https://github.com/someone/Stelix/releases/download/v1.1/Stelix-1.1.dmg", 40_000_000,
             "sha256:" + digest),
            ("Stelix-1.1-lgpl-sources.tar.gz", "https://github.com/someone/Stelix/releases/download/v1.1/src.tar.gz", 9_000_000, nil),
        ]
    ) -> Data {
        let list = assets.map { asset -> [String: Any] in
            var entry: [String: Any] = ["name": asset.name, "browser_download_url": asset.url, "size": asset.size,
                                        "content_type": "application/x-apple-diskimage"]
            entry["digest"] = asset.digest ?? NSNull()
            return entry
        }
        let object: [String: Any] = [
            "tag_name": tag, "name": "Stelix \(tag)", "draft": draft, "prerelease": prerelease,
            "html_url": html, "published_at": "2026-12-02T10:30:00Z", "body": "Notes", "assets": list,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func apiURLFromTheRepository() {
        #expect(GitHubRelease.latestURL(repository: URL(string: "https://github.com/someone/Stelix")!)
            == URL(string: "https://api.github.com/repos/someone/Stelix/releases/latest"))
        #expect(GitHubRelease.latestURL(repository: URL(string: "https://github.com/someone/Stelix.git/")!)
            == URL(string: "https://api.github.com/repos/someone/Stelix/releases/latest"))
        #expect(GitHubRelease.latestURL(repository: URL(string: "https://gitlab.com/someone/Stelix")!) == nil)
        #expect(GitHubRelease.latestURL(repository: URL(string: "http://github.com/someone/Stelix")!) == nil)
        #expect(GitHubRelease.latestURL(repository: URL(string: "https://github.com/someone")!) == nil)
    }

    @Test func readsTheReleaseAndItsDMG() throws {
        let release = try #require(try GitHubRelease.parse(Self.json()))
        #expect(release.version == AppVersion("1.1"))
        #expect(release.notesURL.absoluteString == "https://github.com/someone/Stelix/releases/tag/v1.1")
        #expect(release.dmg.name == "Stelix-1.1.dmg")
        #expect(release.dmg.size == 40_000_000)
        #expect(release.dmg.sha256 == Self.digest)
        #expect(release.dmg.url.absoluteString.hasSuffix("/Stelix-1.1.dmg"))
        #expect(release.published == ISO8601DateFormatter().date(from: "2026-12-02T10:30:00Z"))
    }

    @Test func aDMGWithoutDigestIsStillReadable() throws {
        let data = Self.json(assets: [("Stelix-1.1.dmg", "https://github.com/a/b/x.dmg", 10, nil)])
        let release = try #require(try GitHubRelease.parse(data))
        #expect(release.dmg.sha256 == nil)
    }

    @Test func ignoresWhatIsNotAUsableRelease() throws {
        let cases: [Data] = [
            Self.json(draft: true),
            Self.json(prerelease: true),
            Self.json(tag: "nightly"),
            Self.json(html: "https://evil.example.com/notes"),
            Self.json(html: "http://github.com/someone/Stelix/releases/tag/v1.1"),
            Self.json(assets: []),
            Self.json(assets: [("a.dmg", "https://github.com/a/b/a.dmg", 10, nil), ("b.dmg", "https://github.com/a/b/b.dmg", 10, nil)]),
            Self.json(assets: [("Stelix-1.1.dmg", "http://github.com/a/b/x.dmg", 10, nil)]),
            Self.json(assets: [("Stelix-1.1.dmg", "https://github.com/a/b/x.dmg", 0, nil)]),
            Self.json(assets: [("Stelix-1.1.dmg", "https://github.com/a/b/x.dmg", 3_000_000_000, nil)]),
            Self.json(assets: [("Stelix-1.1.dmg", "https://github.com/a/b/x.dmg", 10, "md5:abc")]),
            Self.json(assets: [("Stelix-1.1.dmg", "https://github.com/a/b/x.dmg", 10, "sha256:xyz")]),
        ]
        for (index, data) in cases.enumerated() {
            #expect(try GitHubRelease.parse(data) == nil, "case \(index)")
        }
    }

    @Test func notJSONIsAnError() {
        #expect(throws: GitHubRelease.Malformed.self) { try GitHubRelease.parse(Data("<html>".utf8)) }
        #expect(throws: GitHubRelease.Malformed.self) { try GitHubRelease.parse(Data("{\"message\":\"x\"}".utf8)) }
    }

    @Test func loopbackIsAcceptedOnlyWhenAsked() throws {
        let data = Self.json(html: "http://127.0.0.1:8000/notes",
                             assets: [("Stelix-1.1.dmg", "http://127.0.0.1:8000/Stelix-1.1.dmg", 10, nil)])
        #expect(try GitHubRelease.parse(data) == nil)
        let release = try #require(try GitHubRelease.parse(data, allowLoopback: true))
        #expect(release.dmg.url.host == "127.0.0.1")
    }
}
