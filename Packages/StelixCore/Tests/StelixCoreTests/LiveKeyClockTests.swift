// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// When the Live analyzes: the tempo every 4 s on 20 s; the key on the last 10 s, every 2 s while none
/// shows and every 4 s while one does (Gabriele, 26/11: the first key and the changes come sooner).
struct LiveKeyClockTests {
    @Test func theKeyWindow() {
        #expect(LiveKeyWindow.seconds == 10)
        #expect(LiveKeyWindow.hop(keyShown: false) == 2)
        #expect(LiveKeyWindow.hop(keyShown: true) == 4)
    }

    @Test func bothAtTheFirstTick() {
        var clock = LiveAnalysisClock()
        let due = clock.due(at: 0, keyShown: false)
        #expect(due.tempo && due.key)
    }

    /// No key on screen: the key every 2 s, the tempo every 4 s.
    @Test func searchingForAKey() {
        var clock = LiveAnalysisClock()
        var dues: [(Bool, Bool)] = []
        for tick in 0...160 {
            let due = clock.due(at: Double(tick) * 0.05, keyShown: false)
            if due.tempo || due.key { dues.append((due.tempo, due.key)) }
        }
        // 0, 2, 4, 6, 8 s.
        #expect(dues.map(\.1) == [true, true, true, true, true])
        #expect(dues.map(\.0) == [true, false, true, false, true])
    }

    /// A key on screen: the key every 4 s, with the tempo.
    @Test func withAKeyShown() {
        var clock = LiveAnalysisClock()
        var keys: [Double] = []
        for tick in 0...160 {
            let now = Double(tick) * 0.05
            if clock.due(at: now, keyShown: true).key { keys.append(now) }
        }
        #expect(keys.count == 3)
    }

    /// A tick with nothing due takes nothing: the next one still finds it due.
    @Test func nothingDueTakesNothing() {
        var clock = LiveAnalysisClock()
        _ = clock.due(at: 0, keyShown: false)
        let early = clock.due(at: 1, keyShown: false)
        #expect(!early.tempo && !early.key)
        #expect(clock.due(at: 2, keyShown: false).key)
    }
}

/// The gap between two songs: half a second below -60 dBFS (Gabriele, 26/11: Music plays the next song
/// at once, with only the silence the files have). It restarts the key, and on reopening the panel a
/// key from before a gap does not come back.
struct LivePauseWatchTests {
    @Test func halfASecond() {
        #expect(LivePauseWatch.seconds == 0.5)
    }

    @Test func musicWithoutAPause() {
        var watch = LivePauseWatch()
        for _ in 0..<200 { watch.observe(peak: 0.3, seconds: 0.05) }
        // A rest shorter than half a second is music.
        for _ in 0..<9 { watch.observe(peak: 0, seconds: 0.05) }
        watch.observe(peak: 0.3, seconds: 0.05)
        #expect(watch.pauses == 0)
        #expect(watch.musicSincePause == nil)
    }

    /// The pause is told once, when it reaches half a second.
    @Test func aPauseIsToldOnce() {
        var watch = LivePauseWatch()
        var told: [Bool] = []
        for _ in 0..<30 { told.append(watch.observe(peak: 0, seconds: 0.05)) }
        #expect(told.filter { $0 }.count == 1)
        #expect(told[9] && !told[8])
        #expect(watch.pauses == 1)
    }

    /// The music after the pause, in seconds: the key window takes only that.
    @Test func musicSinceThePause() {
        var watch = LivePauseWatch()
        for _ in 0..<10 { watch.observe(peak: 0, seconds: 0.05) }
        #expect(watch.musicSincePause == 0)
        for _ in 0..<40 { watch.observe(peak: 0.3, seconds: 0.05) }
        #expect(abs((watch.musicSincePause ?? 0) - 2) < 1e-9)
        watch.observe(peak: 0, seconds: 0.05)
        #expect(abs((watch.musicSincePause ?? 0) - 2.05) < 1e-9)
    }

    @Test func belowTheThresholdIsSilence() {
        var watch = LivePauseWatch()
        for _ in 0..<10 { watch.observe(peak: LiveTempoWindow.threshold / 2, seconds: 0.05) }
        #expect(watch.pauses == 1)
    }

    @Test func twoPausesCountTwice() {
        var watch = LivePauseWatch()
        for _ in 0..<10 { watch.observe(peak: 0, seconds: 0.05) }
        watch.observe(peak: 0.3, seconds: 0.05)
        for _ in 0..<10 { watch.observe(peak: 0, seconds: 0.05) }
        #expect(watch.pauses == 2)
    }
}

/// How much music the Live key reads: the last 10 s, never across a pause, at least 6 s.
struct LiveKeyMusicTests {
    @Test func theLastTenSeconds() {
        #expect(LiveKeyWindow.music(available: 20, sincePause: nil) == 10)
        #expect(LiveKeyWindow.music(available: 8, sincePause: nil) == 8)
    }

    @Test func notAcrossAPause() {
        #expect(LiveKeyWindow.music(available: 20, sincePause: 7) == 7)
    }

    @Test func tooLittleMusicIsNoAnalysis() {
        #expect(LiveKeyWindow.music(available: 20, sincePause: 5) == nil)
        #expect(LiveKeyWindow.music(available: 5, sincePause: nil) == nil)
    }
}
