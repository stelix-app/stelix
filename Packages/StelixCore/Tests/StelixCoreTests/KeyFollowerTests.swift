// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The Live key across analyses: shown once four in a row agree, then kept while the analyses stay among
/// the chords at home in it; gone when two of the last three leave home (Gabriele, 26/11: "if it is
/// unsure, no value", but not "—" every time the song passes through the IV).
struct KeyFollowerTests {
    static let am = MusicalKey(pitchClass: 9, mode: .minor)
    static let c = MusicalKey(pitchClass: 0, mode: .major)

    private static func run(_ estimates: [MusicalKey?]) -> [MusicalKey?] {
        var follower = KeyFollower()
        return estimates.map { follower.observe($0) }
    }

    @Test func fourAnalysesAreNeeded() {
        #expect(KeyFollower.confirmations == 4)
        #expect(Self.run([Self.am, Self.am, Self.am, Self.am]) == [nil, nil, nil, Self.am])
    }

    @Test func staysWhileTheyAgree() {
        #expect(Self.run(Array(repeating: Self.am, count: 7)).suffix(4).allSatisfy { $0 == Self.am })
    }

    // In A minor: C (III), Dm (iv) and E (V) are at home; B♭ and F♯m are not.
    static let dm = MusicalKey(pitchClass: 2, mode: .minor)
    static let e = MusicalKey(pitchClass: 4, mode: .major)
    static let bFlatMajor = MusicalKey(pitchClass: 10, mode: .major)
    static let fSharpMinor = MusicalKey(pitchClass: 6, mode: .minor)
    static var sure: [MusicalKey?] { Array(repeating: am, count: 4) }

    /// The song passes through its chords at home: the key stays.
    @Test func staysWhileTheAnalysesStayAtHome() {
        let out = Self.run(Self.sure + [Self.c, Self.dm, Self.e, Self.c, Self.am])
        #expect(out.suffix(6).allSatisfy { $0 == Self.am })
    }

    /// One analysis away from home is not enough to hide it.
    @Test func oneAnalysisAwayKeepsIt() {
        let out = Self.run(Self.sure + [Self.bFlatMajor, Self.am, Self.c])
        #expect(out.suffix(4).allSatisfy { $0 == Self.am })
    }

    /// Two of the last three away from home: nothing.
    @Test func twoOfTheLastThreeAwayHideIt() {
        #expect(Self.run(Self.sure + [Self.bFlatMajor, Self.bFlatMajor]).last! == nil)
        #expect(Self.run(Self.sure + [Self.bFlatMajor, Self.c, Self.bFlatMajor]).last! == nil)
    }

    /// Away twice but three apart: still the key.
    @Test func awayFarApartKeepsIt() {
        let out = Self.run(Self.sure + [Self.bFlatMajor, Self.c, Self.dm, Self.bFlatMajor])
        #expect(out.last! == Self.am)
    }

    /// Once hidden, it needs four in a row again.
    @Test func afterHidingFourAreNeededAgain() {
        let out = Self.run(Self.sure + [Self.bFlatMajor, Self.bFlatMajor, Self.am, Self.am, Self.am, Self.am])
        #expect(Array(out.suffix(4)) == [nil, nil, nil, Self.am])
    }

    /// Relative keys that alternate (Am, C, Am…) from the start are an unsure key: nothing.
    @Test func alternatingKeysShowNothing() {
        #expect(Self.run([Self.am, Self.c, Self.am, Self.c, Self.am, Self.c]).allSatisfy { $0 == nil })
    }

    /// A key at home that holds four in a row takes over.
    @Test func fourOfAnotherKeyTakeOver() {
        let out = Self.run(Self.sure + [Self.c, Self.c, Self.c, Self.c])
        #expect(Array(out.suffix(4)) == [Self.am, Self.am, Self.am, Self.c])
    }

    /// A modulation away from home: a short "—", then the new key; the old one is never kept across it.
    @Test func aModulationGoesThroughNothing() {
        let out = Self.run(Self.sure + Array(repeating: Self.fSharpMinor, count: 4))
        #expect(Array(out.suffix(4)) == [Self.am, nil, nil, Self.fSharpMinor])
    }

    /// An analysis that finds no key is away from home: two of them hide it.
    @Test func noKeyFoundCountsAsAway() {
        #expect(Self.run(Self.sure + [nil]).last! == Self.am)
        #expect(Self.run(Self.sure + [nil, nil]).last! == nil)
    }

    /// After a reset (silence, a new pipeline) it starts over.
    @Test func resetStartsOver() {
        var follower = KeyFollower()
        for _ in 0..<4 { follower.observe(Self.am) }
        follower.reset()
        #expect(follower.key == nil)
        #expect(follower.observe(Self.am) == nil)
        #expect(follower.observe(Self.c) == nil)
    }

    /// A kept tie keeps how it was written.
    @Test func aKeptTieKeepsItsSpelling() {
        let bFlat = MusicalKey(pitchClass: 10, mode: .major), fSharp = MusicalKey(pitchClass: 6, mode: .major)
        let dSharpMinor = MusicalKey(pitchClass: 3, mode: .minor)
        let out = Self.run([bFlat, fSharp, fSharp, fSharp, fSharp, dSharpMinor])
        #expect(out.last??.name == "G♭")
    }

    /// F♯ or G♭ in the Live: the last analysis that leaned to a side, even an unsure one (Gabriele, 26/11).
    @Test func aTieTakesTheSideOfTheMusicBefore() {
        let bFlat = MusicalKey(pitchClass: 10, mode: .major), fSharp = MusicalKey(pitchClass: 6, mode: .major)
        let out = Self.run([bFlat, fSharp, fSharp, fSharp, fSharp])
        #expect(out.last??.name == "G♭")
        #expect(Self.run([fSharp, fSharp, fSharp, fSharp]).last??.name == "F♯")
    }

    /// Silence is a new song: the side is forgotten.
    @Test func silenceForgetsTheSide() {
        let bFlat = MusicalKey(pitchClass: 10, mode: .major), fSharp = MusicalKey(pitchClass: 6, mode: .major)
        var follower = KeyFollower()
        follower.observe(bFlat)
        follower.reset()
        for _ in 0..<3 { follower.observe(fSharp) }
        #expect(follower.observe(fSharp)?.name == "F♯")
    }

    // MARK: The panel closed and reopened without a pause

    /// The key comes back at once and stays while the new analyses are at home in it.
    @Test func aResumedKeyStaysAtHome() {
        var follower = KeyFollower()
        for _ in 0..<4 { follower.observe(Self.am) }
        follower.resume()
        #expect(follower.key == Self.am)
        #expect(follower.observe(Self.c) == Self.am)
        #expect(follower.observe(Self.am) == Self.am)
    }

    /// Another song meanwhile: two of the first three away and it goes.
    @Test func aResumedKeyGoesIfTheMusicChanged() {
        var follower = KeyFollower()
        for _ in 0..<4 { follower.observe(Self.am) }
        follower.resume()
        follower.observe(Self.fSharpMinor)
        #expect(follower.observe(Self.fSharpMinor) == nil)
    }

    /// The analyses before closing do not count toward a new key: four new ones are needed.
    @Test func aResumeStartsTheRunOver() {
        var follower = KeyFollower()
        for _ in 0..<4 { follower.observe(Self.am) }
        for _ in 0..<3 { follower.observe(Self.c) }
        follower.resume()
        #expect(follower.observe(Self.c) == Self.am)
    }
}
