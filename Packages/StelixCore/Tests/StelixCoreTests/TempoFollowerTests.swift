// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The Live tempo between one analysis and the next: it follows the music but does not jump
/// between half, double and the other metric levels on one analysis.
struct TempoFollowerTests {
    private static func run(_ estimates: [Double?]) -> [Double?] {
        var follower = TempoFollower()
        return estimates.map { follower.observe($0) }
    }

    private static func close(_ a: Double?, _ b: Double, _ tolerance: Double = 0.5) -> Bool {
        a.map { abs($0 - b) <= tolerance } ?? false
    }

    @Test func firstEstimateIsTaken() {
        #expect(Self.run([97]) == [97])
    }

    @Test func followsADrift() {
        let out = Self.run([100, 104, 108, 112])
        #expect(out == [100, 104, 108, 112])
    }

    /// The label has one decimal: changes under 0.3 BPM (the jitter of the estimate on steady music)
    /// keep the number, larger ones show.
    @Test func smallChangesKeepTheNumber() {
        #expect(Self.run([91.5, 91.6, 91.3, 91.9, 92.4]) == [91.5, 91.5, 91.5, 91.9, 92.4])
    }

    /// Measured on the 41 s clip, 20 s windows every 4 s (piani/ricerca-bpm.md).
    @Test func measuredClipStaysAtItsLevel() {
        let out = Self.run([91.5, 91.5, 91.5, 91.5, 181.2, 91.5])
        #expect(out.allSatisfy { Self.close($0, 91.5) })
    }

    /// Measured on the 90 → 150 ramp: three analyses fell to half. The number keeps following the ramp.
    @Test func measuredRampKeepsFollowing() {
        let estimates: [Double] = [107.0, 111.0, 115.2, 119.7, 122.6, 126.9, 130.1, 66.6, 68.9, 71.0, 146.3]
        let out = Self.run(estimates)
        #expect(Self.close(out[7], 133.2, 1))
        #expect(Self.close(out[8], 137.8, 1))
        #expect(Self.close(out[9], 142.0, 1))
        #expect(Self.close(out[10], 146.3))
        // Never below the previous value: the ramp only rises.
        for index in 1..<out.count { #expect(out[index]! >= out[index - 1]!) }
    }

    /// A level that lasts is the music's: after four analyses in a row it is taken.
    @Test func aJumpThatLastsIsTaken() {
        let out = Self.run([120, 60, 60, 60, 60, 60])
        #expect(out[1] == 120 && out[2] == 120 && out[3] == 120)
        #expect(out[4] == 60 && out[5] == 60)
    }

    /// A tempo that is not a metric relative of the current one is a real change: taken at once.
    @Test func aRealChangeIsTakenAtOnce() {
        #expect(Self.run([90, 125]) == [90, 125])
        #expect(Self.run([120, 100]) == [120, 100])
    }

    /// Silence (no estimate) forgets the level: after the pause the first estimate is taken.
    @Test func silenceResets() {
        #expect(Self.run([120, nil, 60]) == [120, nil, 60])
    }
}
