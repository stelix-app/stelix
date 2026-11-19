// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import StelixCore

/// Asks GitHub for the latest release: one GET of a few KB, at most once a day or with Check Now.
/// Nothing about the user goes with it: no identifier, no usage data, a plain User-Agent (GitHub's
/// API asks for one). GitHub sees the IP address, as with any request; the README says so.
struct URLSessionReleaseSource: ReleaseSource {
    static let maxBytes = 1 << 20

    let url: URL
    /// http://127.0.0.1 for the local test (`--update-feed`); otherwise HTTPS only.
    var allowLoopback = false

    func latest() async throws -> Data? {
        guard allows(url) else {
            throw URLError(.unsupportedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Stelix",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Redirects too stay on HTTPS, as in `URLSessionFetcher`.
        let (data, response) = try await session.data(for: request, delegate: RedirectPolicy(allows: allows))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A repository without releases yet.
        if status == 404 { return nil }
        guard status == 200, data.count <= Self.maxBytes else { throw URLError(.badServerResponse) }
        return data
    }

    private func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" || allowLoopback && GitHubRelease.isLoopback(url)
    }
}

/// Follows a redirect only to a URL that `allows` accepts; otherwise the redirect itself is the
/// answer, and its status is not 200.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let allows: @Sendable (URL?) -> Bool

    init(allows: @escaping @Sendable (URL?) -> Bool) {
        self.allows = allows
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(allows(request.url) ? request : nil)
    }
}

/// For `--snapshot … --show update`: a made-up release one minor version above this one, so the
/// banner can be photographed without network or a public repository.
struct SnapshotReleaseSource: ReleaseSource {
    let current: AppVersion

    func latest() async throws -> Data? {
        let parts = current.components + [0]
        let next = "v\(parts[0]).\(parts[1] + 1)"
        let object: [String: Any] = [
            "tag_name": next, "draft": false, "prerelease": false,
            "html_url": "https://github.com/example/Stelix/releases/tag/\(next)",
            "published_at": ISO8601DateFormatter().string(from: Date()),
            "assets": [[
                "name": "Stelix-\(next).dmg", "size": 40_268_000, "digest": NSNull(),
                "browser_download_url": "https://github.com/example/Stelix/releases/download/\(next)/Stelix.dmg",
            ] as [String: Any]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
