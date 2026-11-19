// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// The newest release of the public repository, as GitHub's API describes it
/// (`GET /repos/<owner>/<repo>/releases/latest`, which never returns drafts or pre-releases).
/// No network here: the app fetches the JSON (`URLSessionReleaseSource`) and this reads it.
public struct AvailableUpdate: Equatable, Sendable {
    public struct DiskImage: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int64
        /// Lowercase hexadecimal SHA-256 from the asset's `digest`, when GitHub gives one.
        public let sha256: String?
    }

    public let version: AppVersion
    /// The release page on GitHub, with the notes: what changed, what was fixed.
    public let notesURL: URL
    public let published: Date?
    public let dmg: DiskImage
}

public enum GitHubRelease {
    /// The answer is not a release (an error page, a rate-limit message).
    public struct Malformed: Error, Equatable {}

    /// A DMG larger than this is not ours (the release script stops at 2 GB).
    static let maxSize: Int64 = 2 * 1024 * 1024 * 1024

    /// `https://github.com/<owner>/<repo>` → the API address of its latest release.
    public static func latestURL(repository: URL) -> URL? {
        guard repository.scheme == "https", repository.host?.lowercased() == "github.com" else { return nil }
        let parts = repository.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(repo)/releases/latest")
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool?
        let prerelease: Bool?
        let htmlUrl: String
        let publishedAt: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        let size: Int64
        let digest: String?
    }

    /// The update the JSON describes, or nil when it isn't one Stelix can offer: a draft or a
    /// pre-release, a tag that isn't a version, notes outside github.com, not exactly one `.dmg`,
    /// a size or a digest that make no sense. Throws `Malformed` when the answer isn't a release.
    /// `allowLoopback` (only with `--update-feed`) accepts http://127.0.0.1 for local tests.
    public static func parse(_ data: Data, allowLoopback: Bool = false) throws -> AvailableUpdate? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data) else { throw Malformed() }
        guard release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tagName),
              let notes = URL(string: release.htmlUrl),
              notes.scheme == "https" && notes.host?.lowercased() == "github.com"
                || allowLoopback && isLoopback(notes)
        else { return nil }
        let dmgs = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard dmgs.count == 1, let asset = dmgs.first,
              let url = URL(string: asset.browserDownloadUrl),
              url.scheme == "https" || allowLoopback && isLoopback(url),
              asset.size > 0, asset.size <= maxSize
        else { return nil }
        var sha256: String?
        if let digest = asset.digest {
            guard let hex = sha256Hex(digest) else { return nil }
            sha256 = hex
        }
        let published = release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return AvailableUpdate(
            version: version, notesURL: notes, published: published,
            dmg: .init(name: asset.name, url: url, size: asset.size, sha256: sha256))
    }

    /// "sha256:<64 hex>" → the hex, lowercase.
    private static func sha256Hex(_ digest: String) -> String? {
        guard digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return String(hex)
    }

    /// http://127.0.0.1 or http://localhost: the local test of `--update-feed`.
    public static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }
}
