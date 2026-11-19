// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The channel to a StelixEngine: the real process (`ProcessEngineConnection` in the app),
/// `DemoEngine` for views, fakes in tests.
public protocol EngineConnection: AnyObject, Sendable {
    /// Launches and waits for `.ready` (10 s timeout, then `EngineFailure` "timeout").
    func start() async throws
    func send(_ command: Command)
    /// Ends when the process exits.
    var events: AsyncStream<Event> { get }
    /// `.shutdown`, then at most 0.8 s of waiting, then SIGKILL. Idempotent.
    func terminate() async
}

/// The contract of `terminate()`, in one place: asks to exit, waits at most `grace`,
/// then kills and waits for the exit to really arrive (at most `killWait`), so the caller
/// does not launch a new engine while the old one is still alive.
public enum EngineStop {
    public static let grace: Duration = .milliseconds(800)
    /// After SIGKILL the exit arrives in a few ms; the limit avoids hanging if it never arrives.
    public static let killWait: Duration = .milliseconds(200)

    /// - Returns: `true` if the kill was needed.
    @discardableResult
    public static func perform(grace: Duration = EngineStop.grace,
                               requestShutdown: @Sendable () -> Void,
                               waitForExit: @escaping @Sendable () async -> Void,
                               kill: @Sendable () -> Void) async -> Bool {
        requestShutdown()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waitForExit(); return true }
            group.addTask { try? await Task.sleep(for: grace); return false }
            let exitedInTime = await group.next() ?? false
            if !exitedInTime {
                kill()
                // The grace timer has already finished: waitForExit remains, plus a new limit.
                group.addTask { try? await Task.sleep(for: killWait); return false }
                _ = await group.next()
            }
            group.cancelAll()
            return !exitedInTime
        }
    }
}

public enum ModePhase: Equatable, Sendable {
    case preparing, active, stopping, failed(EngineFailure)
}
