// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct LiveAudioPresenceTests {
    /// Ticks at 20 Hz without signal from `from` to `to`; returns the results.
    private func silence(_ presence: inout LiveAudioPresence, from: Double, to: Double) -> [(Double, Bool)] {
        var out: [(Double, Bool)] = []
        var t = from
        while t <= to + 1e-9 {
            out.append((t, presence.observe(signal: false)))
            t += 0.05
        }
        return out
    }

    @Test func waitsFromTheStart() {
        var presence = LiveAudioPresence()
        #expect(presence.waiting)
        let results = silence(&presence, from: 0, to: 20)
        #expect(results.allSatisfy { $0.1 })
    }

    @Test func firstSampleEndsTheWaitAtOnce() {
        var presence = LiveAudioPresence()
        _ = silence(&presence, from: 0, to: 2.95)
        let afterSample = presence.observe(signal: true)
        #expect(afterSample == false)
        #expect(!presence.waiting)
    }

    @Test func silenceAfterSoundNeverWaitsAgain() {
        // Paused while choosing the next song: Live stays ready, no "Waiting" (Gabriele, 27/11).
        // The 5 minutes of LiveIdleTimer still turn it off.
        var presence = LiveAudioPresence()
        _ = presence.observe(signal: true)
        let pause = silence(&presence, from: 10.05, to: 400)
        #expect(pause.allSatisfy { !$0.1 })
        #expect(!presence.waiting)
    }

    // MARK: Before playing

    private static let settle: Int64 = 24_000      // half a second at 48 kHz

    private func beforePlay(written: Int64, newFrames: Bool, outputRunning: Bool, waiting: Bool)
        -> LiveAudioPresence.BeforePlay {
        LiveAudioPresence.beforePlay(written: written, newFrames: newFrames, outputRunning: outputRunning,
                                     waiting: waiting, settleFrames: Self.settle)
    }

    @Test func noFramesWithTheOutputClosedWaits() {
        #expect(beforePlay(written: 0, newFrames: false, outputRunning: false, waiting: true) == .waitForAudio)
    }

    @Test func theOutputOpenBeforeTheFirstCallbackHolds() {
        // The tap has not called yet: too early to say there is no sound (the old flash of "Waiting").
        #expect(beforePlay(written: 0, newFrames: false, outputRunning: true, waiting: true) == .hold)
    }

    @Test func theFirstCallbacksWithoutSoundHold() {
        #expect(beforePlay(written: 4_800, newFrames: true, outputRunning: true, waiting: true) == .hold)
    }

    @Test func halfASecondOfZerosWaits() {
        #expect(beforePlay(written: Self.settle, newFrames: true, outputRunning: true, waiting: true) == .waitForAudio)
    }

    @Test func soundFills() {
        #expect(beforePlay(written: 4_800, newFrames: true, outputRunning: true, waiting: false) == .fill)
    }
}
