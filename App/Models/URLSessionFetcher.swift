// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import StelixCore
import Synchronization

/// The only download in Stelix: one model file, or the DMG of an update, asked for with a click.
/// Engine and sidecar never see it.
///
/// A data task whose delegate writes each chunk straight to `destination` (in `Models/.downloads`),
/// so the half-written file is always Stelix's to delete. `URLSession.download(for:)` was tried on
/// 2026-11-09 and dropped: on Cancel or a dropped connection it leaves its temporary file (hundreds
/// of MB) in the system's temporary folder without saying where, and its download delegate never
/// reports progress. Chunks arrive in tens of KB, not byte by byte as with `AsyncBytes`.
struct URLSessionFetcher: ModelFetcher {
    static let progressInterval: Duration = .milliseconds(100)

    /// Which URLs and redirects it follows: HTTPS only, plus http://127.0.0.1 for the local test
    /// of updates (`--update-feed`), where the signature check still decides.
    var allows: @Sendable (URL?) -> Bool = ModelFetchPolicy.allows

    func fetch(_ url: URL, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard allows(url) else { throw ModelFetchError.unavailable(status: 0) }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw ModelStoreError.write
        }
        let writer = ChunkWriter(handle: handle, expectedSize: expectedSize, allows: allows, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: writer, delegateQueue: nil)
        // The session keeps its delegate until it's invalidated.
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    writer.start(task, continuation: continuation)
                }
            } onCancel: {
                task.cancel()
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

/// Writes the chunks of one data task to a file and turns the way it ended into the fetcher's
/// errors. Past `expectedSize` (announced or received) it stops at once: a source that streams
/// without end must not fill the disk before the SHA-256 check.
private final class ChunkWriter: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var written: Int64 = 0
        var lastReport = ContinuousClock.now
        /// Why Stelix stopped the task itself (status, size, disk).
        var failure: (any Error)?
    }

    private let handle: FileHandle
    private let expectedSize: Int64
    private let allows: @Sendable (URL?) -> Bool
    private let progress: @Sendable (Int64) -> Void
    private let state = Mutex(State())

    init(handle: FileHandle, expectedSize: Int64, allows: @escaping @Sendable (URL?) -> Bool,
         progress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.expectedSize = expectedSize
        self.allows = allows
        self.progress = progress
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.continuation = continuation }
        task.resume()
    }

    /// GitHub and Hugging Face answer with a redirect to their CDN. It is followed only if it stays
    /// on HTTPS; otherwise the redirect itself becomes the answer, and its status is not 200.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(allows(request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            stop(ModelFetchError.unavailable(status: status))
            completionHandler(.cancel)
        } else if response.expectedContentLength > expectedSize {
            stop(ModelFetchError.tooLarge)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLock { $0.written + Int64(data.count) > expectedSize }
        guard !tooLarge else {
            stop(ModelFetchError.tooLarge)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            stop(ModelStoreError.write)
            dataTask.cancel()
            return
        }
        let report: Int64? = state.withLock { s in
            s.written += Int64(data.count)
            let now = ContinuousClock.now
            guard now - s.lastReport >= URLSessionFetcher.progressInterval else { return nil }
            s.lastReport = now
            return s.written
        }
        if let report { progress(report) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure, written) = state.withLock { s in
            defer { s.continuation = nil }
            return (s.continuation, s.failure, s.written)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error = error as? URLError {
            continuation.resume(throwing: error.code == .cancelled ? CancellationError() : ModelFetchError.network)
        } else if error != nil {
            continuation.resume(throwing: ModelFetchError.network)
        } else {
            progress(written)
            continuation.resume()
        }
    }

    private func stop(_ failure: any Error) {
        state.withLock { if $0.failure == nil { $0.failure = failure } }
    }
}
