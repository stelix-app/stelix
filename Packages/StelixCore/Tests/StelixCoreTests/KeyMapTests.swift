// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The key at the playback instant, from the time ranges of an analysis.
struct KeyMapTests {
    static let am = MusicalKey(pitchClass: 9, mode: .minor)
    static let c = MusicalKey(pitchClass: 0, mode: .major)

    @Test func insideASpan() {
        let map = KeyMap(spans: [KeySpan(start: 0, end: 30, key: Self.am), KeySpan(start: 30, end: 60, key: Self.c)])
        #expect(map.key(at: 10) == Self.am)
        #expect(map.key(at: 45) == Self.c)
    }

    @Test func boundaryBelongsToTheNextSpan() {
        let map = KeyMap(spans: [KeySpan(start: 0, end: 30, key: Self.am), KeySpan(start: 30, end: 60, key: Self.c)])
        #expect(map.key(at: 30) == Self.c)
    }

    /// A short gap between ranges, or the end of the last one, does not make the key blink off.
    @Test func shortGapKeepsTheNearestKey() {
        let map = KeyMap(spans: [KeySpan(start: 0, end: 30, key: Self.am), KeySpan(start: 33, end: 60, key: Self.c)])
        #expect(map.key(at: 31) == Self.am)
        #expect(map.key(at: 32.5) == Self.c)
        #expect(map.key(at: 61.5) == Self.c)
    }

    @Test func farFromEverySpanGivesNothing() {
        let map = KeyMap(spans: [KeySpan(start: 10, end: 20, key: Self.am)])
        #expect(map.key(at: 5) == nil)
        #expect(map.key(at: 25) == nil)
    }

    @Test func emptyMapGivesNothing() {
        #expect(KeyMap(spans: []).key(at: 0) == nil)
    }

    @Test func overlapTakesTheLaterSpan() {
        let map = KeyMap(spans: [KeySpan(start: 0, end: 40, key: Self.am), KeySpan(start: 30, end: 60, key: Self.c)])
        #expect(map.key(at: 35) == Self.c)
    }

    @Test func unsortedSpansAreSorted() {
        let map = KeyMap(spans: [KeySpan(start: 30, end: 60, key: Self.c), KeySpan(start: 0, end: 30, key: Self.am)])
        #expect(map.spans.map(\.start) == [0, 30])
        #expect(map.key(at: 10) == Self.am)
    }
}
