// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization
import Testing
@testable import StelixCore

/// A fake process whose exit arrives when `exit()` is called, even later.
private final class FakeProcess: Sendable {
    let exited = Mutex(false)
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func exit() {
        exited.withLock { $0 = true }
        continuation.finish()
    }

    func waitForExit() async { for await _ in stream {} }
}

struct EngineStopTests {
    @Test func waitsForExitAfterKill() async {
        let process = FakeProcess()
        let killed = await EngineStop.perform(
            grace: .milliseconds(50),
            requestShutdown: {},
            waitForExit: { await process.waitForExit() },
            kill: {
                // SIGKILL is not instant: the exit arrives 100 ms later.
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(100))
                    process.exit()
                }
            })
        #expect(killed)
        #expect(process.exited.withLock { $0 })
    }

    @Test func returnsEvenIfExitNeverArrivesAfterKill() async {
        let process = FakeProcess()
        let started = ContinuousClock.now
        let killed = await EngineStop.perform(
            grace: .milliseconds(50),
            requestShutdown: {},
            waitForExit: { await process.waitForExit() },
            kill: {})
        #expect(killed)
        // 250 ms nominal (grace plus `killWait`). Without the limit it would wait forever: the bound only
        // has to tell the two apart. Under parallel tests (or a Mac in swap) the sleeps wake late, and
        // 500 ms failed at 542 and 628 ms.
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func noKillWhenProcessExitsInTime() async {
        let process = FakeProcess()
        let killCount = Mutex(0)
        let killed = await EngineStop.perform(
            grace: .milliseconds(500),
            requestShutdown: { process.exit() },
            waitForExit: { await process.waitForExit() },
            kill: { killCount.withLock { $0 += 1 } })
        #expect(!killed)
        #expect(killCount.withLock { $0 } == 0)
    }
}
