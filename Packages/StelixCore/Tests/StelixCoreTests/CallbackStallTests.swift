// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct CallbackStallTests {
    @Test func noCallbacksForSixSecondsStalls() {
        var stall = CallbackStall()
        let r1 = stall.observe(now: 0, written: 0); #expect(!r1)
        let r2 = stall.observe(now: 5.9, written: 0); #expect(!r2)
        let r3 = stall.observe(now: 6.1, written: 0); #expect(r3)
    }

    @Test func callbacksThatStopStallAfterTwoSeconds() {
        var stall = CallbackStall()
        let r1 = stall.observe(now: 0, written: 0); #expect(!r1)
        let r2 = stall.observe(now: 1, written: 4_800); #expect(!r2)
        let r3 = stall.observe(now: 2, written: 9_600); #expect(!r3)
        let r4 = stall.observe(now: 3.9, written: 9_600); #expect(!r4)
        let r5 = stall.observe(now: 4.1, written: 9_600); #expect(r5)
    }

    @Test func steadyCallbacksNeverStall() {
        var stall = CallbackStall()
        var written: Int64 = 0
        for tick in 0..<400 {
            written += 2_400
            let r1 = stall.observe(now: Double(tick) * 0.05, written: written); #expect(!r1)
        }
    }

    @Test func lateFirstCallbackIsFine() {
        // In early measurements the first callbacks arrived up to 5 s after the start.
        var stall = CallbackStall()
        let r1 = stall.observe(now: 0, written: 0); #expect(!r1)
        let r2 = stall.observe(now: 5, written: 512); #expect(!r2)
        let r3 = stall.observe(now: 6.5, written: 512); #expect(!r3)
        let r4 = stall.observe(now: 7.1, written: 512); #expect(r4)
    }

    /// After an output change the new tap starts from scratch: its first callbacks can arrive
    /// up to 5 s later, and the frames already written do not count as progress.
    @Test func restartWaitsForTheStartupTimeoutAgain() {
        var stall = CallbackStall()
        _ = stall.observe(now: 0, written: 0)
        _ = stall.observe(now: 1, written: 48_000)
        stall.restart(written: 48_000)
        let r1 = stall.observe(now: 1.1, written: 48_000); #expect(!r1)
        let r2 = stall.observe(now: 5, written: 48_000); #expect(!r2)
        let r3 = stall.observe(now: 7.2, written: 48_000); #expect(r3)
    }

    @Test func restartThenFramesMoveAgain() {
        var stall = CallbackStall()
        _ = stall.observe(now: 0, written: 0)
        _ = stall.observe(now: 1, written: 48_000)
        stall.restart(written: 48_000)
        _ = stall.observe(now: 1.1, written: 48_000)
        let r1 = stall.observe(now: 2, written: 50_000); #expect(!r1)
        let r2 = stall.observe(now: 4.1, written: 50_000); #expect(r2)
    }

    /// Record pressed with the Mac silent: no callbacks until the output does IO, and it is not an error.
    @Test func silentMacIsNotAStall() {
        var stall = CallbackStall()
        for tick in 0...300 {
            let r = stall.observe(now: Double(tick) * 0.05, written: 0, outputRunning: false); #expect(!r)
        }
        let r1 = stall.observe(now: 15.05, written: 0, outputRunning: true); #expect(!r1)
        let r2 = stall.observe(now: 20.9, written: 0, outputRunning: true); #expect(!r2)
        let r3 = stall.observe(now: 21.2, written: 0, outputRunning: true); #expect(r3)
    }

    @Test func pauseWithoutCallbacksAfterStartIsNotAStall() {
        var stall = CallbackStall()
        _ = stall.observe(now: 0, written: 0)
        _ = stall.observe(now: 1, written: 48_000)
        let r1 = stall.observe(now: 5, written: 48_000, outputRunning: false); #expect(!r1)
        let r2 = stall.observe(now: 6.5, written: 48_000, outputRunning: true); #expect(!r2)
        let r3 = stall.observe(now: 7.1, written: 48_000, outputRunning: true); #expect(r3)
    }
}
