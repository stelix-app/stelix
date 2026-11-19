// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// At most one send every `interval` seconds, and the last request always goes out.
///
/// The caller, on `.sendAt(t)`, schedules a send for instant `t` that reads the most
/// recent value at that moment and then calls `fired(at:)`. Requests that arrive while a send
/// is already scheduled (`.alreadyScheduled`) do nothing: that send picks them up.
/// Times are monotonic-clock seconds, passed in by the caller.
public struct SendThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        case sendNow
        case sendAt(Double)
        case alreadyScheduled
    }

    public let interval: Double
    private var lastSent: Double?
    private var scheduled = false

    public init(interval: Double) {
        self.interval = interval
    }

    public mutating func request(at now: Double) -> Decision {
        if scheduled { return .alreadyScheduled }
        guard let last = lastSent, now - last < interval - 1e-9 else {
            lastSent = now
            return .sendNow
        }
        scheduled = true
        return .sendAt(last + interval)
    }

    /// The scheduled send has fired.
    public mutating func fired(at now: Double) {
        scheduled = false
        lastSent = now
    }
}
