// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

/// A Live level on a Mac slower than the one it was measured on (M3 Max): the pass gets more time,
/// and the delay grows, instead of the model falling behind.
struct LiveScheduleTests {
    @Test func levelIsKeptWithoutAMeasurement() {
        for level in LiveLevel.allCases {
            let s = LiveSchedule(level: level)
            #expect(s == LiveSchedule.fitting(level: level, passSeconds: nil))
            #expect(!s.isStretched)
            #expect(abs(s.delay - level.targetDelay) < 1e-9)
            #expect(s.modelBudget == level.modelBudget)
        }
    }

    /// The M3 Max passes (htdemucs 0.19 s, htdemucs_ft 0.78-0.84 s) keep the levels as they are.
    @Test func m3MaxKeepsTheLevels() {
        #expect(LiveSchedule.fitting(level: .base, passSeconds: 0.19) == LiveSchedule(level: .base))
        #expect(LiveSchedule.fitting(level: .intermediate, passSeconds: 0.19) == LiveSchedule(level: .intermediate))
        #expect(LiveSchedule.fitting(level: .pro, passSeconds: 0.84) == LiveSchedule(level: .pro))
    }

    /// A chip like the M2 (htdemucs about 0.4-0.7 s): Base and Intermediate get a longer hop and margin,
    /// the pass uses at most 70% of its time, and the delay stays within the maximum.
    @Test func slowerMacStretchesHopAndMargin() throws {
        // 0.3 s fits Intermediate (0.5 s) but not Base (0.3 s).
        #expect(LiveSchedule.fitting(level: .intermediate, passSeconds: 0.3) == LiveSchedule(level: .intermediate))
        #expect(LiveSchedule.fitting(level: .base, passSeconds: 0.3)?.isStretched == true)
        for pass in [0.45, 0.6, 0.7] {
            for level in [LiveLevel.base, .intermediate] {
                let s = try #require(LiveSchedule.fitting(level: level, passSeconds: pass))
                #expect(s.isStretched)
                #expect(pass <= LiveSchedule.stretchedLoad * s.modelBudget + 1e-9)
                #expect(s.hop >= level.hop)
                #expect(s.margin >= level.margin)
                #expect(s.lookahead == level.lookahead)
                #expect(s.delay <= LiveSchedule.maxDelay + 1e-9)
                #expect(s.delay > level.targetDelay)
            }
        }
        // 0.6 s per pass: 0.6 / 0.7 = 0.857, rounded up to 0.9 s of hop and of margin + lookahead.
        let s = try #require(LiveSchedule.fitting(level: .intermediate, passSeconds: 0.6))
        #expect(abs(s.hop - 0.9) < 1e-9)
        #expect(abs(s.margin - 0.65) < 1e-9)
        #expect(abs(s.delay - 1.8) < 1e-9)
    }

    /// Too slow even with the longest delay: the level does not run on this Mac.
    @Test func tooSlowForTheLongestDelayIsNil() {
        #expect(LiveSchedule.fitting(level: .intermediate, passSeconds: 2.0) == nil)
        #expect(LiveSchedule.fitting(level: .pro, passSeconds: 2.5) == nil)    // htdemucs_ft on a chip like the M2
        #expect(LiveSchedule.fitting(level: .pro, passSeconds: 1.1) != nil)    // on a Pro chip
        // 1.7 s still fits Pro: 2.45 s of hop, 4.9 s of delay. 1.8 s would need 5.15 s.
        let pro = LiveSchedule.fitting(level: .pro, passSeconds: 1.7)
        #expect(pro.map { abs($0.delay - 4.9) < 1e-9 } == true)
        #expect(LiveSchedule.fitting(level: .pro, passSeconds: 1.8) == nil)
    }

    /// The stretched schedule still fits the 7.8 s window and the 10 s timeline at every rate.
    @Test func stretchedScheduleFitsWindowAndTimeline() throws {
        for level in LiveLevel.allCases {
            for pass in stride(from: 0.1, through: 2.5, by: 0.05) {
                guard let s = LiveSchedule.fitting(level: level, passSeconds: pass) else { continue }
                #expect(s.hop + s.lookahead + LiveTiming.crossfadeSeconds + 0.05 < 7.8)
                #expect(s.delay + s.hop + s.lookahead < 10)
            }
        }
    }

    @Test func timingCarriesTheSchedule() throws {
        let s = try #require(LiveSchedule.fitting(level: .base, passSeconds: 0.6))
        let t = LiveTiming(level: .base, schedule: s, deviceRate: 48_000)
        #expect(t.hopFrames == Int((s.hop * 48_000).rounded()))
        #expect(t.lookaheadFrames == Int((s.lookahead * 48_000).rounded()))
        #expect(t.delayFrames == Int((s.delay * 48_000).rounded()))
        #expect(t.modelBudget == s.modelBudget)
        #expect(t.isStretched)
        #expect(LiveTiming(level: .base, deviceRate: 48_000) == LiveTiming(level: .base, schedule: LiveSchedule(level: .base), deviceRate: 48_000))
    }

    /// The real pipeline with a model as slow as a chip like the M2: the level's own timing falls behind,
    /// the stretched one plays without gaps and with its (longer) delay.
    @Test func slowModelPlaysCleanlyOnlyWithTheStretchedSchedule() throws {
        let window = Int((7.8 * 44_100).rounded())
        let pass = 0.6
        let level = LiveLevel.intermediate
        let plain = LiveSimulator(level: level, deviceRate: 48_000, model: IdentityModel(windowFrames: window),
                                  modelLatency: pass)
        plain.constant = 0.5
        plain.run(callbacks: 900, framesPerCallback: 512)
        #expect(!plain.playing || plain.underruns > 0)

        let s = try #require(LiveSchedule.fitting(level: level, passSeconds: pass))
        let stretched = LiveSimulator(timing: LiveTiming(level: level, schedule: s, deviceRate: 48_000),
                                      model: IdentityModel(windowFrames: window), modelLatency: pass)
        stretched.constant = 0.5
        stretched.run(callbacks: 900, framesPerCallback: 512)
        #expect(stretched.playing)
        #expect(stretched.underruns == 0)
    }

    /// What the delay measurement should find: the fixed delay, plus the time pitch's latency while the
    /// Live is transposed (the drums wait for it too).
    @Test func expectedDelayIncludesTheTransposeLatency() {
        let timing = LiveTiming(level: .intermediate, deviceRate: 48_000)
        #expect(timing.expectedDelaySeconds(extraFrames: 0) == 1.0)
        #expect(abs(timing.expectedDelaySeconds(extraFrames: 4096) - (1.0 + 4096.0 / 48_000)) < 1e-9)
    }
}
