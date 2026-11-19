// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct SendThrottleTests {
    @Test func firstRequestGoesAtOnce() {
        var throttle = SendThrottle(interval: 1.0 / 30)
        #expect(throttle.request(at: 10) == .sendNow)
    }

    @Test func requestInsideIntervalIsScheduledAtItsEnd() {
        var throttle = SendThrottle(interval: 0.1)
        _ = throttle.request(at: 10)
        #expect(throttle.request(at: 10.04) == .sendAt(10.1))
        // Already queued: the scheduled send will read the most recent value.
        #expect(throttle.request(at: 10.06) == .alreadyScheduled)
        throttle.fired(at: 10.1)
        #expect(throttle.request(at: 10.15) == .sendAt(10.2))
    }

    @Test func requestAfterIntervalGoesAtOnce() {
        var throttle = SendThrottle(interval: 0.1)
        _ = throttle.request(at: 10)
        #expect(throttle.request(at: 10.1) == .sendNow)
        #expect(throttle.request(at: 10.5) == .sendNow)
    }

    /// A slider drag of 1000 events per second: at most 30 sends plus the first,
    /// and the last value always goes out, after the last request.
    @Test func dragAtOneKilohertzSendsAtMostThirtyPerSecondAndTheLast() {
        var throttle = SendThrottle(interval: 1.0 / 30)
        var sends: [Double] = []
        var pending: Double?
        for step in 0..<1000 {
            let now = Double(step) / 1000
            if let at = pending, now >= at {
                throttle.fired(at: at)
                sends.append(at)
                pending = nil
            }
            switch throttle.request(at: now) {
            case .sendNow: sends.append(now)
            case .sendAt(let at): pending = at
            case .alreadyScheduled: break
            }
        }
        if let at = pending {
            throttle.fired(at: at)
            sends.append(at)
        }
        #expect(sends.count <= 31)
        #expect(sends.count >= 29)
        #expect((sends.last ?? 0) >= 0.999)
        for (a, b) in zip(sends, sends.dropFirst()) {
            #expect(b - a >= 1.0 / 30 - 1e-9)
        }
    }
}
