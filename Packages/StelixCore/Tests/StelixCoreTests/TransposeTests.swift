// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The transpose value: from -12 to +12 semitones, 0 means off.
struct TransposeTests {
    @Test func clampsToTwelve() {
        #expect(Transpose(semitones: 15).semitones == 12)
        #expect(Transpose(semitones: -20).semitones == -12)
    }

    @Test func zeroIsOff() {
        #expect(Transpose.off.isOff && Transpose(semitones: 0) == .off)
        #expect(!Transpose(semitones: 1).isOff)
    }

    @Test func stepsMoveByOne() {
        #expect(Transpose.off.raised().semitones == 1)
        #expect(Transpose.off.lowered().semitones == -1)
    }

    /// The stepper's arrows stop at the ends.
    @Test func stepsStopAtTheEnds() {
        let top = Transpose(semitones: 12), bottom = Transpose(semitones: -12)
        #expect(top.raised() == top && !top.canRaise && top.canLower)
        #expect(bottom.lowered() == bottom && !bottom.canLower && bottom.canRaise)
    }

    /// What the user types in the field: a number from -12 to +12, with or without a sign (also the
    /// typographic minus the field shows) and with or without " st".
    @Test(arguments: [("5", 5), ("+5", 5), ("-3", -3), ("\u{2212}3", -3), (" 7 ", 7), ("+3 st", 3),
                      ("\u{2212}5 st", -5), ("0", 0), ("12", 12), ("-12", -12), ("+0", 0), ("4st", 4)])
    func parsesTypedValues(text: String, semitones: Int) {
        #expect(Transpose(typed: text) == Transpose(semitones: semitones))
    }

    /// Anything else is refused, not clamped: the panel keeps the value it had and shows the range.
    @Test(arguments: ["", " ", "13", "-13", "20", "abc", "3.5", "3,5", "++3", "+-3", "3 4", "st", "1e1", "३"])
    func refusesOtherText(text: String) {
        #expect(Transpose(typed: text) == nil)
    }

    /// The suffix of a saved Studio folder: a plain hyphen, safe in file names.
    @Test(arguments: [(0, ""), (3, " +3 st"), (-5, " -5 st"), (12, " +12 st"), (-12, " -12 st")])
    func folderSuffix(semitones: Int, suffix: String) {
        #expect(Transpose(semitones: semitones).folderSuffix == suffix)
    }
}
