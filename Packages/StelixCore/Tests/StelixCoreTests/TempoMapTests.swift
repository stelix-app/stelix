// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The local tempo: 60 over the median of the beat intervals around a point.
struct TempoMapTests {
    /// Beats at `bpm` from `start` for `count` beats.
    private static func grid(_ bpm: Double, from start: Double = 0, count: Int) -> [Double] {
        (0..<count).map { start + Double($0) * 60 / bpm }
    }

    @Test func steadyGridGivesItsTempo() throws {
        let map = TempoMap(beats: Self.grid(86, from: 0.4, count: 100))
        for time in [0.0, 0.4, 10, 35.5, 69] {
            #expect(abs(try #require(map.bpm(at: time)) - 86) < 0.01)
        }
    }

    /// 90 BPM for 30 s, then 120: the number follows, with a few beats of transition.
    @Test func followsATempoChange() throws {
        let first = Self.grid(90, count: 45)
        let second = Self.grid(120, from: first.last! + 0.5, count: 60)
        let map = TempoMap(beats: first + second)
        #expect(abs(try #require(map.bpm(at: 10)) - 90) < 0.01)
        #expect(abs(try #require(map.bpm(at: 50)) - 120) < 0.01)
    }

    /// One beat the analysis missed makes one interval twice as long: the median ignores it.
    @Test func aMissedBeatDoesNotMoveTheNumber() throws {
        var beats = Self.grid(100, count: 60)
        beats.remove(at: 30)
        let map = TempoMap(beats: beats)
        #expect(abs(try #require(map.bpm(at: beats[29])) - 100) < 0.01)
    }

    @Test func fewerThanTwoBeatsGiveNothing() {
        #expect(TempoMap(beats: []).bpm(at: 0) == nil)
        #expect(TempoMap(beats: [1]).bpm(at: 1) == nil)
    }

    /// Before the first beat and after the last one, a little margin, then nothing.
    @Test func outsideTheBeatsGivesNothing() {
        let map = TempoMap(beats: Self.grid(120, from: 10, count: 20))   // 10 ... 19.5 s
        #expect(map.bpm(at: 9) != nil)
        #expect(map.bpm(at: 5) == nil)
        #expect(map.bpm(at: 21) != nil)
        #expect(map.bpm(at: 30) == nil)
    }

    /// A tempo nobody plays is not shown.
    @Test func implausibleTemposAreDropped() {
        #expect(TempoMap(beats: Self.grid(400, count: 40)).bpm(at: 2) == nil)
        #expect(TempoMap(beats: Self.grid(20, count: 10)).bpm(at: 10) == nil)
    }

    /// Unsorted input (it should not happen) is sorted, not trusted.
    @Test func unsortedBeatsAreSorted() throws {
        let map = TempoMap(beats: Self.grid(100, count: 30).reversed())
        #expect(abs(try #require(map.bpm(at: 5)) - 100) < 0.01)
    }

    /// For the Live: read near the end of a window, the tempo of the beats around that point.
    @Test func nearTheEndOfAWindow() throws {
        let first = Self.grid(80, count: 30)
        let second = Self.grid(110, from: first.last! + 60 / 110, count: 12)
        let map = TempoMap(beats: first + second)
        #expect(abs(try #require(map.bpm(at: second[8])) - 110) < 0.01)
        #expect(abs(try #require(map.bpm(at: first[20])) - 80) < 0.01)
    }
}

/// The Studio label: the local tempo where the player is, a dash where the stems are silent.
struct StemsResultTempoTests {
    /// 60 s, beats at 120 BPM all along; the stems are silent from 20 to 40 s.
    private static func result(beats: [Double]?) -> StemsResult {
        let peaks: [Float] = (0..<600).map { bin in (200..<400).contains(bin) ? 0 : 0.4 }
        return StemsResult(folder: "/f", files: [:], duration: 60,
                           waveforms: [.drums: peaks, .vocals: peaks.map { $0 / 2 }],
                           beats: beats)
    }

    @Test func tempoWhereThereIsMusic() throws {
        let result = Self.result(beats: (0..<120).map { Double($0) * 0.5 })
        #expect(abs(try #require(result.bpm(at: 10)) - 120) < 0.01)
        #expect(abs(try #require(result.bpm(at: 50)) - 120) < 0.01)
    }

    /// The analysis puts beats on silence too (measured): there the label says "—".
    @Test func dashWhereTheStemsAreSilent() {
        let result = Self.result(beats: (0..<120).map { Double($0) * 0.5 })
        #expect(result.bpm(at: 30) == nil)
    }

    /// Stems from before this feature, or an analysis that failed.
    @Test func noBeatsGiveNothing() {
        #expect(Self.result(beats: nil).bpm(at: 10) == nil)
    }

    /// Without peaks (they are not needed to play) only the beats decide.
    @Test func noWaveformsMeansNoSilenceCheck() {
        let result = StemsResult(folder: "/f", files: [:], duration: 60, waveforms: [:],
                                 beats: (0..<120).map { Double($0) * 0.5 })
        #expect(result.bpm(at: 30) != nil)
    }
}
