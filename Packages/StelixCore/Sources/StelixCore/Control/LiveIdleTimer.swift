// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Decides when Live turns itself off: after `limit` seconds in which the Mac plays nothing.
/// "Nothing" is the output not running (many players close it on pause) or a signal below `threshold`
/// (some apps keep the output open while paused and send zeros). The count starts when
/// Live is turned on, so it runs during the model load and the wait for audio too.
///
/// Times are monotonic-clock seconds, passed in by the caller.
public struct LiveIdleTimer: Sendable {
    /// 5 minutes, fixed: a safety limit, not a preference.
    public static let limit: Double = 300
    /// -60 dBFS on the input peak: well below a quiet tail, well above digital zeros.
    public static let threshold: Float = 0.001

    private var lastSound: Double

    public init(startedAt now: Double) {
        lastSound = now
    }

    /// To be called at regular intervals. `peak`: the largest absolute input sample since the
    /// previous call (0 if no frames arrived). `true` when the time is up.
    public mutating func observe(at now: Double, outputRunning: Bool, peak: Float) -> Bool {
        if outputRunning, peak >= Self.threshold {
            lastSound = now
            return false
        }
        return now - lastSound >= Self.limit
    }

    /// The output has changed (headphones plugged in, for example): whoever does it is about
    /// to listen, so the count starts over.
    public mutating func outputChanged(at now: Double) {
        lastSound = now
    }
}
