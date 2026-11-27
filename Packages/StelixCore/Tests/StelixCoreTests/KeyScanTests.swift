// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

/// The Studio key over the clip: 20 s windows every 4 s, a key only where four windows in a row agree
/// (Gabriele, 26/11: the sections and the modulations, never an unsure key).
struct KeyScanTests {
    static let am = MusicalKey(pitchClass: 9, mode: .minor)
    static let c = MusicalKey(pitchClass: 0, mode: .major)

    private static func scan(_ duration: Double, _ keys: [MusicalKey?], from first: Int = 0) -> KeyScan {
        KeyScan(duration: duration, windows: keys.enumerated().map { KeyWindow(index: first + $0.offset, key: $0.element) })
    }

    @Test(arguments: [(19.9, 0), (20.0, 1), (23.9, 1), (24.0, 2), (36.0, 5), (216.0, 50)])
    func windowsCoverTheClip(duration: Double, count: Int) {
        #expect(KeyScan(duration: duration).windowCount == count)
    }

    /// One window at a time: the scan runs alongside the separation and takes half of what two would
    /// (Gabriele, 27/11); the same windows, so the same keys.
    @Test func oneWindowAtATime() {
        #expect(KeyScan.concurrent == 1)
    }

    @Test func aWindowStartsEveryFourSeconds() {
        #expect(KeyScan.seconds == 20 && KeyScan.hop == 4)
        #expect(KeyScan(duration: 60).start(of: 3) == 12)
    }

    /// Four alike from the first window: from the start of the clip to the middle of the hop after the
    /// last of them.
    @Test func aRunAtTheStartBeginsAtZero() {
        let scan = Self.scan(60, [Self.am, Self.am, Self.am, Self.am, Self.c])
        // Window 3 starts at 12 s: its center is 22 s, and the span ends half a hop later.
        #expect(scan.spans == [KeySpan(start: 0, end: 24, key: Self.am)])
    }

    @Test func threeAlikeAreNotEnough() {
        #expect(Self.scan(60, [Self.am, Self.am, Self.am, Self.c, Self.c]).spans.isEmpty)
    }

    /// In the middle a section goes from half a hop before the center of its first window to half a hop
    /// after the center of its last.
    @Test func aRunInTheMiddle() {
        let scan = Self.scan(120, [Self.c, Self.am, Self.am, Self.am, Self.am, Self.c])
        #expect(scan.spans == [KeySpan(start: 12, end: 28, key: Self.am)])
    }

    /// A run that reaches the last window goes to the end of the clip.
    @Test func aRunAtTheEndReachesTheEnd() {
        // 36 s: windows 0...4, the last at 16-36 s.
        let scan = Self.scan(36, [Self.c, Self.am, Self.am, Self.am, Self.am])
        #expect(scan.spans == [KeySpan(start: 12, end: 36, key: Self.am)])
    }

    /// A window not analyzed yet, or one that found no key, breaks the run.
    @Test func aMissingOrEmptyWindowBreaksTheRun() {
        var scan = Self.scan(120, [Self.am, Self.am, nil, Self.am, Self.am])
        #expect(scan.spans.isEmpty)
        scan = KeyScan(duration: 120, windows: [0, 1, 3, 4].map { KeyWindow(index: $0, key: Self.am) })
        #expect(scan.spans.isEmpty)
    }

    /// The order of arrival does not matter.
    @Test func windowsInAnyOrder() {
        let scan = KeyScan(duration: 60, windows: [3, 0, 2, 1].map { KeyWindow(index: $0, key: Self.am) })
        #expect(scan.spans == [KeySpan(start: 0, end: 24, key: Self.am)])
    }

    /// A clip with fewer than four windows needs all of them, at least two.
    @Test func shortClips() {
        #expect(Self.scan(24, [Self.am, Self.am]).spans == [KeySpan(start: 0, end: 24, key: Self.am)])
        #expect(Self.scan(24, [Self.am, Self.c]).spans.isEmpty)
        #expect(Self.scan(20, [Self.am]).spans.isEmpty)
    }

    @Test func keyAtTimeIsOnlyInsideASection() {
        let scan = Self.scan(120, [Self.c, Self.am, Self.am, Self.am, Self.am, Self.c])
        #expect(scan.key(at: 12) == Self.am)
        #expect(scan.key(at: 27.9) == Self.am)
        #expect(scan.key(at: 28) == nil)
        #expect(scan.key(at: 11.9) == nil)
    }

    /// Complete with every window in and the whole track's key looked for (found or not).
    @Test func completeWhenEveryWindowIsIn() {
        var scan = Self.scan(36, [Self.am, Self.am, Self.am, Self.am])
        scan.setTrackKey(nil)
        #expect(!scan.isComplete)
        scan.add(KeyWindow(index: 4, key: nil))
        #expect(scan.isComplete)
    }

    @Test func notCompleteWithoutTheTrackKey() {
        let scan = Self.scan(36, [Self.am, Self.am, Self.am, Self.am, Self.am])
        #expect(!scan.isComplete)
    }

    /// The same window twice (an engine that redoes it) counts once, the newer.
    @Test func addReplacesAWindow() {
        var scan = Self.scan(60, [Self.am])
        scan.add(KeyWindow(index: 0, key: Self.c))
        #expect(scan.windows == [KeyWindow(index: 0, key: Self.c)])
    }

    /// Next is the missing window whose center is nearest to where the user listens; ties go ahead.
    @Test func nextIsNearTheListeningPoint() {
        let empty = KeyScan(duration: 216)
        #expect(empty.next(around: 0) == 0)
        // Centers are at 10, 14, 18…: 100 s is nearest to window 22 (center 98) and 23 (center 102): ahead.
        #expect(empty.next(around: 100) == 23)
        #expect(empty.next(around: 1_000) == 49)
        let started = Self.scan(216, [Self.am, Self.am, Self.am])
        #expect(started.next(around: 0) == 3)
    }

    /// Windows being analyzed are skipped.
    @Test func nextSkipsTheWindowsInProgress() {
        #expect(KeyScan(duration: 216).next(around: 0, excluding: [0]) == 1)
        #expect(KeyScan(duration: 24).next(around: 0, excluding: [0, 1]) == nil)
    }

    @Test func nothingNextWhenComplete() {
        #expect(Self.scan(24, [Self.am, Self.am]).next(around: 5) == nil)
        #expect(KeyScan(duration: 10).next(around: 0) == nil)
    }

    // MARK: F♯ or G♭, by the music around

    static let fSharp = MusicalKey(pitchClass: 6, mode: .major)
    static let bFlat = MusicalKey(pitchClass: 10, mode: .major)
    static let gm = MusicalKey(pitchClass: 7, mode: .minor)
    static let b = MusicalKey(pitchClass: 11, mode: .major)
    static let e = MusicalKey(pitchClass: 4, mode: .major)

    private static func names(_ duration: Double, _ keys: [MusicalKey?]) -> [String] {
        scan(duration, keys).spans.map(\.key.name)
    }

    @Test func aTieAmongFlatsIsGFlat() {
        #expect(Self.names(80, [Self.gm, Self.fSharp, Self.fSharp, Self.fSharp, Self.fSharp, Self.bFlat]) == ["G♭"])
    }

    @Test func aTieAmongSharpsIsFSharp() {
        #expect(Self.names(80, [Self.e, Self.fSharp, Self.fSharp, Self.fSharp, Self.fSharp, Self.b]) == ["F♯"])
    }

    /// The two sides disagree: the one the music comes from.
    @Test func theSideBeforeWins() {
        #expect(Self.names(80, [Self.gm, Self.fSharp, Self.fSharp, Self.fSharp, Self.fSharp, Self.b]) == ["G♭"])
        #expect(Self.names(80, [Self.b, Self.fSharp, Self.fSharp, Self.fSharp, Self.fSharp, Self.gm]) == ["F♯"])
    }

    /// Only after: the side after. Windows with no key, C or Am, or a tie say nothing and are skipped.
    @Test func theNearestWindowThatLeans() {
        #expect(Self.names(80, [Self.fSharp, Self.fSharp, Self.fSharp, Self.fSharp, nil, Self.am, Self.bFlat]) == ["G♭"])
    }

    @Test func nothingAroundKeepsSharps() {
        #expect(Self.names(32, [Self.fSharp, Self.fSharp, Self.fSharp, Self.fSharp]) == ["F♯"])
    }

    // MARK: Gaps and the track's key: "—" only where it is really unsure

    // A made-up song in G: its chords at home and two away from it.
    static let g = MusicalKey(pitchClass: 7, mode: .major)
    static let d = MusicalKey(pitchClass: 2, mode: .major)
    static let em = MusicalKey(pitchClass: 4, mode: .minor)
    static let bm = MusicalKey(pitchClass: 11, mode: .minor)
    static let gMinor = MusicalKey(pitchClass: 7, mode: .minor)
    static let aFlat = MusicalKey(pitchClass: 8, mode: .major)

    /// One or two windows that disagree between two sections in the same key: one section.
    @Test(arguments: [1, 2])
    func aShortGapBetweenTheSameKeyIsBridged(gap: Int) {
        let keys = Array(repeating: Self.e, count: 4) + Array(repeating: Self.b, count: gap)
            + Array(repeating: Self.e, count: 4)
        #expect(Self.scan(Double(20 + 4 * (keys.count - 1)), keys).spans.map(\.key) == [Self.e])
    }

    @Test func aLongerGapIsNot() {
        let keys = Array(repeating: Self.e, count: 4) + [Self.b, Self.am, Self.b] + Array(repeating: Self.e, count: 4)
        #expect(Self.scan(Double(20 + 4 * (keys.count - 1)), keys).spans.count == 2)
    }

    @Test func aGapBetweenTwoKeysIsNotBridged() {
        let keys = Array(repeating: Self.e, count: 4) + [Self.b] + Array(repeating: Self.d, count: 4)
        #expect(Self.scan(Double(20 + 4 * (keys.count - 1)), keys).spans.map(\.key) == [Self.e, Self.d])
    }

    /// Where the windows wander among the chords at home in the track's key (I, ii, iii, IV, V, vi, the
    /// parallel minor), the track's key: four of the five windows around at least.
    @Test func wanderingAtHomeShowsTheTrackKey() {
        var scan = Self.scan(60, [Self.g, Self.d, Self.em, Self.c, Self.g, Self.am, Self.gMinor,
                                  Self.bm, Self.d, Self.g, Self.em])
        scan.setTrackKey(Self.g)
        #expect(scan.spans == [KeySpan(start: 0, end: 60, key: Self.g)])
    }

    @Test func noTrackKeyNoFallback() {
        let scan = Self.scan(60, [Self.g, Self.d, Self.em, Self.c, Self.g, Self.am, Self.gMinor,
                                  Self.bm, Self.d, Self.g, Self.em])
        #expect(scan.spans.isEmpty)
    }

    /// Windows away from home (here A♭ and B♭ in G) stay unsure.
    @Test func wanderingAwayStaysUnsure() {
        var scan = Self.scan(60, [Self.aFlat, Self.bFlat, Self.g, Self.aFlat, Self.bFlat, Self.aFlat, Self.bFlat,
                                  Self.g, Self.aFlat, Self.bFlat, Self.aFlat])
        scan.setTrackKey(Self.g)
        #expect(scan.spans.isEmpty)
    }

    /// Windows not analyzed yet are not at home: the fallback waits for them.
    @Test func theFallbackWaitsForTheWindows() {
        var scan = KeyScan(duration: 60, windows: [KeyWindow(index: 0, key: Self.g), KeyWindow(index: 1, key: Self.d)])
        scan.setTrackKey(Self.g)
        #expect(scan.spans.isEmpty)
    }

    /// A sure section keeps its own key also at home (C is the IV of G).
    @Test func aSureSectionWinsOverTheFallback() {
        var scan = Self.scan(60, [Self.g, Self.d, Self.em, Self.c, Self.c, Self.c, Self.c,
                                  Self.g, Self.d, Self.em, Self.g])
        scan.setTrackKey(Self.g)
        #expect(scan.spans.map(\.key.name) == ["G", "C", "G"])
    }

    @Test func trackKeyTravelsInJSON() throws {
        var scan = Self.scan(60, [Self.g])
        scan.setTrackKey(Self.g)
        let back = try JSONDecoder().decode(KeyScan.self, from: JSONEncoder().encode(scan))
        #expect(back == scan && back.trackKey == Self.g)
    }
}
