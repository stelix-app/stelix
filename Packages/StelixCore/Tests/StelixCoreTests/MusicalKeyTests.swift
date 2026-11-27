// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

/// Key names after a transpose: the spelling with the fewest accidentals (Am +3 is Cm, not B♯m).
struct MusicalKeyTests {
    static let major = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    static let minor = ["Cm", "C♯m", "Dm", "D♯m", "Em", "Fm", "F♯m", "Gm", "G♯m", "Am", "B♭m", "Bm"]

    @Test(arguments: 0..<12)
    func namesEveryKey(pitchClass: Int) {
        #expect(MusicalKey(pitchClass: pitchClass, mode: .major).name == Self.major[pitchClass])
        #expect(MusicalKey(pitchClass: pitchClass, mode: .minor).name == Self.minor[pitchClass])
    }

    @Test func aMinorPlusThreeIsCMinor() {
        #expect(MusicalKey(pitchClass: 9, mode: .minor).transposed(by: 3).name == "Cm")
    }

    @Test func wrapsAroundTheOctave() {
        let b = MusicalKey(pitchClass: 11, mode: .major), am = MusicalKey(pitchClass: 9, mode: .minor)
        #expect(b.transposed(by: 1).name == "C")
        #expect(MusicalKey(pitchClass: 0, mode: .major).transposed(by: -1) == b)
        #expect(am.transposed(by: 12) == am && am.transposed(by: -12) == am)
    }

    /// F♯/G♭ and D♯m/E♭m have six accidentals either way: sharps, so a key and its relative
    /// share the key signature.
    @Test func tiesUseSharps() {
        #expect(MusicalKey(pitchClass: 6, mode: .major).name == "F♯")
        #expect(MusicalKey(pitchClass: 3, mode: .minor).name == "D♯m")
    }

    @Test func pitchClassIsNormalized() {
        #expect(MusicalKey(pitchClass: -3, mode: .minor) == MusicalKey(pitchClass: 9, mode: .minor))
        #expect(MusicalKey(pitchClass: 25, mode: .major).pitchClass == 1)
    }

    @Test func modeIsKept() {
        #expect(MusicalKey(pitchClass: 9, mode: .minor).transposed(by: 5).mode == .minor)
    }

    @Test func tonicNameDropsTheMode() {
        #expect(MusicalKey(pitchClass: 1, mode: .minor).tonicName == "C♯")
        #expect(MusicalKey(pitchClass: 3, mode: .major).tonicName == "E♭")
        #expect(MusicalKey(pitchClass: 9, mode: .minor).tonicName == "A")
    }

    /// A line from the engine is not trusted: a pitch class out of range is normalized, not a crash in `name`.
    @Test func decodingNormalizesThePitchClass() throws {
        let key = try JSONDecoder().decode(MusicalKey.self, from: Data(#"{"pitchClass":15,"mode":"minor"}"#.utf8))
        #expect(key.pitchClass == 3)
        #expect(key.name == "D♯m")
    }

    // MARK: The tie spelled by the music around (Gabriele, 26/11)

    @Test func tiesFollowTheSpelling() {
        #expect(MusicalKey(pitchClass: 6, mode: .major, spelling: .flats).name == "G♭")
        #expect(MusicalKey(pitchClass: 3, mode: .minor, spelling: .flats).name == "E♭m")
        #expect(MusicalKey(pitchClass: 3, mode: .minor, spelling: .flats).tonicName == "E♭")
        #expect(MusicalKey(pitchClass: 6, mode: .major, spelling: .sharps).name == "F♯")
    }

    /// Only the two ties change: D♭ has five flats against seven sharps whatever the music around.
    @Test func otherKeysIgnoreTheSpelling() {
        #expect(MusicalKey(pitchClass: 1, mode: .major, spelling: .sharps).name == "D♭")
        #expect(MusicalKey(pitchClass: 8, mode: .minor, spelling: .flats).name == "G♯m")
    }

    /// The same key however it is written: followers and maps compare keys.
    @Test func spellingDoesNotChangeTheKey() {
        let flat = MusicalKey(pitchClass: 6, mode: .major, spelling: .flats)
        let plain = MusicalKey(pitchClass: 6, mode: .major)
        #expect(flat == plain)
        #expect(Set([flat, plain]).count == 1)
    }

    /// The side of the key signature a key leans to; none for C and Am, nor for the ties.
    @Test(arguments: [(3, MusicalKey.Mode.major, MusicalKey.Spelling.flats), (0, .minor, .flats), (11, .major, .sharps),
                      (4, .minor, .sharps), (5, .major, .flats), (7, .major, .sharps)])
    func sideOfTheSignature(pitchClass: Int, mode: MusicalKey.Mode, side: MusicalKey.Spelling) {
        #expect(MusicalKey(pitchClass: pitchClass, mode: mode).side == side)
    }

    @Test func noSideForCAndTheTies() {
        #expect(MusicalKey(pitchClass: 0, mode: .major).side == nil)
        #expect(MusicalKey(pitchClass: 9, mode: .minor).side == nil)
        #expect(MusicalKey(pitchClass: 6, mode: .major).side == nil)
        #expect(MusicalKey(pitchClass: 3, mode: .minor).side == nil)
    }

    @Test func transposeKeepsTheSpelling() {
        let gFlat = MusicalKey(pitchClass: 6, mode: .major, spelling: .flats)
        #expect(gFlat.transposed(by: 12).name == "G♭")
        #expect(MusicalKey(pitchClass: 4, mode: .major, spelling: .flats).transposed(by: 2).name == "G♭")
    }

    @Test func spellingTravelsInJSON() throws {
        let gFlat = MusicalKey(pitchClass: 6, mode: .major, spelling: .flats)
        let back = try JSONDecoder().decode(MusicalKey.self, from: JSONEncoder().encode(gFlat))
        #expect(back.name == "G♭")
        let old = try JSONDecoder().decode(MusicalKey.self, from: Data(#"{"pitchClass":6,"mode":"major"}"#.utf8))
        #expect(old.spelling == nil && old.name == "F♯")
    }

    /// The chords at home in a key: I, ii, iii, IV, V, vi and the parallel minor; in a minor key i, III,
    /// iv, v, V, VI, VII and the parallel major.
    @Test func homeOfAMajorKey() {
        let d = MusicalKey(pitchClass: 2, mode: .major)
        let home = [(2, MusicalKey.Mode.major), (4, .minor), (6, .minor), (7, .major), (9, .major), (11, .minor), (2, .minor)]
        for (pc, mode) in home { #expect(MusicalKey(pitchClass: pc, mode: mode).isAtHome(in: d)) }
        for (pc, mode) in [(3, MusicalKey.Mode.major), (10, .major), (5, .major), (4, .major), (1, .major)] {
            #expect(!MusicalKey(pitchClass: pc, mode: mode).isAtHome(in: d))
        }
    }

    @Test func homeOfAMinorKey() {
        let am = MusicalKey(pitchClass: 9, mode: .minor)
        let home = [(9, MusicalKey.Mode.minor), (0, .major), (2, .minor), (4, .minor), (4, .major), (5, .major), (7, .major), (9, .major)]
        for (pc, mode) in home { #expect(MusicalKey(pitchClass: pc, mode: mode).isAtHome(in: am)) }
        #expect(!MusicalKey(pitchClass: 11, mode: .major).isAtHome(in: am))
    }
}
