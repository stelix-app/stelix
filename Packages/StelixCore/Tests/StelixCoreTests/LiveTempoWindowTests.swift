// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// Which part of the last 20 s of the Live is music to analyze.
struct LiveTempoWindowTests {
    private static let loud: Float = 0.3
    private static let quiet: Float = 0

    /// Peaks of `seconds` of audio, one per block.
    private static func blocks(_ seconds: Double, _ peak: Float) -> [Float] {
        Array(repeating: peak, count: Int((seconds / LiveTempoWindow.blockSeconds).rounded()))
    }

    @Test func allMusicIsAnalyzedWhole() {
        #expect(LiveTempoWindow.musicSeconds(peaks: Self.blocks(20, Self.loud)) == 20)
    }

    /// The Mac is silent now: no analysis, the label says "—".
    @Test func silentTailGivesNothing() {
        let peaks = Self.blocks(17, Self.loud) + Self.blocks(3, Self.quiet)
        #expect(LiveTempoWindow.musicSeconds(peaks: peaks) == nil)
    }

    /// After a pause only the music after it counts, and only from 6 s on.
    @Test func afterAPauseWaitsForEnoughMusic() {
        let pause = Self.blocks(8, Self.loud) + Self.blocks(4, Self.quiet)
        #expect(LiveTempoWindow.musicSeconds(peaks: pause + Self.blocks(4, Self.loud)) == nil)
        #expect(LiveTempoWindow.musicSeconds(peaks: pause + Self.blocks(8, Self.loud)) == 8)
    }

    /// A rest under the limit is part of the music, also at the very end.
    @Test func aShortRestDoesNotCount() {
        let peaks = Self.blocks(10, Self.loud) + Self.blocks(1, Self.quiet) + Self.blocks(8.5, Self.loud)
            + Self.blocks(0.5, Self.quiet)
        #expect(LiveTempoWindow.musicSeconds(peaks: peaks) == 20)
    }

    @Test func emptyGivesNothing() {
        #expect(LiveTempoWindow.musicSeconds(peaks: []) == nil)
    }

    /// A quiet tail at -50 dBFS is still music; digital zeros and -70 dBFS are not.
    @Test func thresholdIsTheIdleOne() {
        #expect(LiveTempoWindow.musicSeconds(peaks: Self.blocks(10, 0.003)) == 10)
        #expect(LiveTempoWindow.musicSeconds(peaks: Self.blocks(10, 0.0003)) == nil)
    }

    /// The number is read where the user listens: the newest input minus the Live delay, plus half
    /// of the time the number stays on screen. Never past the end of the music analyzed.
    @Test func tempoIsReadWhereTheUserListens() {
        #expect(LiveTempoWindow.listeningTime(musicSeconds: 20, delaySeconds: 3) == 20 - 3 + LiveTempoWindow.hop / 2)
        #expect(LiveTempoWindow.listeningTime(musicSeconds: 20, delaySeconds: 1) == 20)
        #expect(LiveTempoWindow.listeningTime(musicSeconds: 6, delaySeconds: 5) == 6 - 5 + LiveTempoWindow.hop / 2)
    }
}
