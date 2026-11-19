// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Notices that the IOProc no longer gives audio: no callback for `startupTimeout` seconds
/// from the start (in early measurements the first ones arrived up to 5 s late), or frames stopped for
/// `gapTimeout` seconds after they had started (device unplugged, AirPods switched off). The time is
/// the one the caller passes, in seconds. While the output does no IO (`outputRunning` false,
/// that is, the Mac is silent) there is no stall: the tap calls only when something plays.
public struct CallbackStall: Sendable {
    public let startupTimeout: Double
    public let gapTimeout: Double
    private var start: Double?
    private var lastWritten: Int64 = 0
    private var lastAdvance: Double?

    public init(startupTimeout: Double = 6, gapTimeout: Double = 2) {
        self.startupTimeout = startupTimeout
        self.gapTimeout = gapTimeout
    }

    /// A new tap on the same ring (output change): start again with `startupTimeout`, counting
    /// l'avanzamento da `written`.
    public mutating func restart(written: Int64) {
        start = nil
        lastWritten = written
        lastAdvance = nil
    }

    /// `true` if the audio has stopped.
    public mutating func observe(now: Double, written: Int64, outputRunning: Bool = true) -> Bool {
        if start == nil { start = now }
        if written > lastWritten {
            lastWritten = written
            lastAdvance = now
            return false
        }
        if !outputRunning {
            // Mac silent: the output does no IO and the tap does not call the callback. Wait, and the times
            // restart from here.
            if lastAdvance != nil { lastAdvance = now } else { start = now }
            return false
        }
        if let lastAdvance { return now - lastAdvance > gapTimeout }
        return now - start! > startupTimeout
    }
}
