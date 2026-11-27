// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Decides when Live is waiting for the Mac's audio: from the start until the first non-zero sample.
///
/// Silence is exact zeros or no frames at all. Some apps keep the output open while nothing plays
/// (Safari with a paused video, Logic) and send exact zeros: at the start that is the same as a silent Mac.
/// After the first sound a pause is not a wait: Live stays ready (the model skips windows of exact
/// silence) until `LiveIdleTimer` turns it off after 5 minutes (Gabriele, 27/11).
public struct LiveAudioPresence: Sendable {
    public private(set) var waiting = true

    public init() {}

    /// `signal`: at least one non-zero sample since the previous call. Returns `waiting`.
    public mutating func observe(signal: Bool) -> Bool {
        if signal { waiting = false }
        return waiting
    }
}

extension LiveAudioPresence {
    /// What Live says before it plays: wait for audio, fill, or nothing yet (the start text stays).
    public enum BeforePlay: Equatable, Sendable { case waitForAudio, fill, hold }

    /// Seconds of frames, all zeros, before Live says it waits: the first callbacks can come before the
    /// first sound, and with music playing "Waiting" would flash at every start.
    public static let settleSeconds = 0.5

    /// Before playing. `newFrames`: frames arrived since the previous tick; `written`: frames since the start
    /// of the pipeline; `settleFrames`: `settleSeconds` at the device rate.
    public static func beforePlay(written: Int64, newFrames: Bool, outputRunning: Bool, waiting: Bool,
                                  settleFrames: Int64) -> BeforePlay {
        // Mac silent with the output closed: no frames until something plays.
        if !outputRunning, !newFrames { return .waitForAudio }
        guard waiting else { return .fill }
        // Only exact zeros so far: an app holds the output open, once there are enough of them to tell.
        return written >= settleFrames ? .waitForAudio : .hold
    }
}
