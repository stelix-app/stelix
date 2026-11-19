// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization

/// A line of `stelix_sidecar.py` on stdout. Lines that are not of these three types are ignored.
public enum SidecarMessage: Equatable, Sendable {
    case progress(Double, JobStep)
    case done([Stem: String])
    case error(EngineFailure)

    public static func parse(_ line: Data) -> SidecarMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["error"] is String {
            // The code comes from the message; an unknown message is worth "Separation failed".
            let message = (object["message"] as? String).flatMap(FailureMessage.init(rawValue:)) ?? .separationFailed
            var detail = object["detail"] as? String
            // The sidecar names the missing file; as in the engine, `detail` is the model.
            if message == .missingWeights, let name = detail, let package = ModelCatalog.shipped.package(containing: name) {
                detail = package.id.rawValue
            }
            return .error(EngineFailure(message, detail: detail))
        }
        if (object["done"] as? Bool) == true, let raw = object["files"] as? [String: String] {
            var files: [Stem: String] = [:]
            for (key, path) in raw {
                guard let stem = Stem(rawValue: key) else { return nil }
                files[stem] = path
            }
            return .done(files)
        }
        if let value = object["progress"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            // A step the app does not know (or that is missing) is worth "Separating…".
            let step = (object["step"] as? String).flatMap(JobStep.init(rawValue:)) ?? .separating
            return .progress(value.doubleValue, step)
        }
        return nil
    }
}

/// The sidecar process for a single Intermediate or Pro Studio job.
///
/// - stdout is read by lines until EOF, and every recognized line goes to `onMessage`;
/// - stdin is a pipe that stays open for the whole job: if the engine dies (even `kill -9`) it
///   closes, and the sidecar exits by itself;
/// - stderr is the engine's (logs end up in the same place);
/// - `terminate()` sends SIGTERM and, if after `grace` seconds the process is still alive, SIGKILL.
public final class SidecarProcess: Sendable {
    public static let notFound = EngineFailure(.sidecarMissing)
    public static let cancelled = EngineFailure(.separationCancelled)

    public struct Exit: Equatable, Sendable {
        public var status: Int32
        /// `true` if a signal closed it: then `status` is the signal number.
        public var signaled: Bool

        public init(status: Int32, signaled: Bool) {
            self.status = status
            self.signaled = signaled
        }
    }

    private struct State {
        var pid: pid_t = 0
        /// For the delayed SIGKILL: `isRunning` becomes false when Foundation reaps the
        /// process, before `terminationHandler`, so the pid cannot already belong to another.
        var process: Process?
        var exited = false
        var cancelled = false
    }

    private let executable: URL
    private let arguments: [String]
    private let grace: Double
    private let state = Mutex(State())

    public init(executable: URL, arguments: [String], grace: Double = 1) {
        self.executable = executable
        self.arguments = arguments
        self.grace = grace
    }

    public var wasCancelled: Bool { state.withLock { $0.cancelled } }

    /// Launches, delivers the lines and waits for the process to end. Blocking: must be called from a work
    /// queue, never from main.
    public func run(onMessage: (SidecarMessage) -> Void) throws(EngineFailure) -> Exit {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Self.notFound }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let exited = DispatchSemaphore(value: 0)
        let writeEnd = input.fileHandleForWriting
        process.terminationHandler = { [self] _ in
            state.withLock { $0.exited = true }
            // Any grandchild that reads stdin sees it close and does not keep stdout open.
            try? writeEnd.close()
            exited.signal()
        }

        // Launch under lock: a parallel terminate() either finds the pid, or stops the launch.
        let launched: Result<Void, EngineFailure> = state.withLock { state in
            if state.cancelled { return .failure(Self.cancelled) }
            do { try process.run() } catch { return .failure(Self.notFound) }
            state.pid = process.processIdentifier
            state.process = process
            return .success(())
        }
        try launched.get()

        let reader = output.fileHandleForReading
        // With the same 1 MiB cap as the engine's lines: a line that never ends does not grow in memory.
        var lines = LineSplitter()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            for case .success(let line) in lines.feed(chunk) {
                if let message = SidecarMessage.parse(line) { onMessage(message) }
            }
        }
        if let last = lines.finish(), let message = SidecarMessage.parse(last) { onMessage(message) }
        try? reader.close()
        exited.wait()
        return Exit(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal)
    }

    /// SIGTERM at once, SIGKILL after `grace` seconds if needed. Before the launch it prevents the launch.
    /// It can be called from any thread, even several times.
    public func terminate() {
        let pid: pid_t? = state.withLock { state in
            state.cancelled = true
            return state.pid > 0 && !state.exited ? state.pid : nil
        }
        guard let pid else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            state.withLock { state in
                if !state.exited, state.process?.isRunning == true { kill(pid, SIGKILL) }
            }
        }
    }
}
