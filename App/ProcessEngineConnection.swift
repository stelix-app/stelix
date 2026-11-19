// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import os
import StelixCore
import Synchronization

/// StelixEngine as a child process: commands on stdin, events on stdout, logs on stderr.
/// If Stelix dies, the engine's stdin closes and the engine exits by itself.
///
/// `@unchecked Sendable`: `Process` and `Pipe` are not marked Sendable, but here they are configured only once
/// in `start()` and then used only through thread-safe APIs (file handle, pid, handler).
/// All the mutable state lives in the `Mutex`.
final class ProcessEngineConnection: EngineConnection, @unchecked Sendable {
    static let readyTimeout: Duration = .seconds(10)
    private static let log = Logger(subsystem: "io.github.stelix-app.stelix", category: "engine")

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let exitStream: AsyncStream<Void>
    private let exitContinuation: AsyncStream<Void>.Continuation

    private let executableURL: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    /// Writes to stdin never block the main thread.
    private let writer = DispatchQueue(label: "io.github.stelix-app.stelix.engine-stdin")

    private struct State {
        var decoder = LineDecoder<Event>()
        var launched = false
        var ready = false
        var waitCancelled = false
        var readyWaiter: CheckedContinuation<Void, Error>?
        var exited = false
        var outputClosed = false
        var finished = false
        var stdinClosed = false
        var termination: Task<Void, Never>?
    }
    private let state = Mutex(State())

    init(executableURL: URL) {
        self.executableURL = executableURL
        (events, continuation) = AsyncStream.makeStream()
        (exitStream, exitContinuation) = AsyncStream.makeStream()
    }

    // MARK: - EngineConnection

    func start() async throws {
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        // The engine's log goes into the system log line by line, without the names of the user's
        // devices and without the home folder (`LogRelay`).
        let relay = Mutex(LogRelay())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let lines = relay.withLock { data.isEmpty ? $0.finish() : $0.feed(data) }
            for line in lines { Self.log.info("\(line, privacy: .public)") }
        }
        process.terminationHandler = { [weak self] _ in self?.didExit() }

        do {
            try process.run()
        } catch {
            Self.log.error("launch failed: \(LogPrivacy.redact(error.localizedDescription), privacy: .public)")
            finishStreams()
            throw EngineFailure(.engineLaunch)
        }
        state.withLock { $0.launched = true }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitForReady() }
            group.addTask {
                try await Task.sleep(for: Self.readyTimeout)
                throw EngineFailure(.engineTimeout)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ command: Command) {
        guard let line = try? LineCodec.encode(command) else { return }
        let handle = input.fileHandleForWriting
        writer.async { [weak self] in
            guard let self, !self.state.withLock({ $0.stdinClosed }) else { return }
            // SIGPIPE is ignored (StelixApp): if the engine is dead the write simply fails.
            try? handle.write(contentsOf: line)
        }
    }

    func terminate() async {
        let task = state.withLock { s -> Task<Void, Never>? in
            guard s.launched else { return nil }
            if let existing = s.termination { return existing }
            let task = Task {
                _ = await EngineStop.perform(
                    requestShutdown: {
                        self.send(.shutdown)
                        self.closeStdin()
                    },
                    waitForExit: { for await _ in self.exitStream {} },
                    kill: {
                        let pid = self.process.processIdentifier
                        if pid > 0 { Darwin.kill(pid, SIGKILL) }
                    })
            }
            s.termination = task
            return task
        }
        await task?.value
    }

    // MARK: - I/O

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            let done = state.withLock { s -> Bool in
                s.outputClosed = true
                return s.exited
            }
            if done { finishStreams() }
            return
        }
        let (results, waiter) = state.withLock { s -> ([Result<Event, Error>], CheckedContinuation<Void, Error>?) in
            let results = s.decoder.feed(data)
            var waiter: CheckedContinuation<Void, Error>?
            if !s.ready, results.contains(where: { (try? $0.get()) == .ready }) {
                s.ready = true
                waiter = s.readyWaiter
                s.readyWaiter = nil
            }
            return (results, waiter)
        }
        waiter?.resume()
        for result in results {
            switch result {
            case .success(let event): continuation.yield(event)
            case .failure(let error):
                Self.log.error("unreadable line from the engine: \(LogPrivacy.redact(error.localizedDescription), privacy: .public)")
            }
        }
    }

    private func waitForReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let immediate = state.withLock { s -> Result<Void, Error>? in
                    if s.ready { return .success(()) }
                    if s.exited { return .failure(EngineFailure(.engineExited)) }
                    if s.waitCancelled { return .failure(CancellationError()) }
                    s.readyWaiter = waiter
                    return nil
                }
                if let immediate { waiter.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
                s.waitCancelled = true
                defer { s.readyWaiter = nil }
                return s.readyWaiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func didExit() {
        let (waiter, outputClosed) = state.withLock { s -> (CheckedContinuation<Void, Error>?, Bool) in
            s.exited = true
            defer { s.readyWaiter = nil }
            return (s.readyWaiter, s.outputClosed)
        }
        waiter?.resume(throwing: EngineFailure(.engineExited))
        closeStdin()
        if outputClosed {
            finishStreams()
        } else {
            // Usually stdout's EOF arrives at once; if a grandchild keeps the pipe open, we do not wait longer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.finishStreams() }
        }
    }

    private func closeStdin() {
        writer.async { [weak self] in
            guard let self else { return }
            let first = self.state.withLock { s -> Bool in
                defer { s.stdinClosed = true }
                return !s.stdinClosed
            }
            if first { try? self.input.fileHandleForWriting.close() }
        }
    }

    private func finishStreams() {
        let first = state.withLock { s -> Bool in
            defer { s.finished = true }
            return !s.finished
        }
        guard first else { return }
        continuation.finish()
        exitContinuation.finish()
    }
}
