// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct SpeedTests {
    @Test func clampsToTheRange() {
        #expect(Speed(percent: 40).percent == 50)
        #expect(Speed(percent: 160).percent == 150)
        #expect(Speed.normal.percent == 100)
        #expect(Speed.normal.isNormal)
        #expect(!Speed(percent: 95).isNormal)
    }

    /// The arrows step by 5 and snap to the grid: from a typed 82, up is 85 and down is 80.
    @Test func arrowsSnapToTheGrid() {
        #expect(Speed(percent: 82).raised().percent == 85)
        #expect(Speed(percent: 82).lowered().percent == 80)
        #expect(Speed(percent: 80).raised().percent == 85)
        #expect(Speed(percent: 80).lowered().percent == 75)
        #expect(Speed(percent: 124).raised().percent == 125)
        #expect(Speed(percent: 125).raised().percent == 130)
        #expect(Speed(percent: 149).raised().percent == 150)
        #expect(Speed(percent: 150).raised().percent == 150)
        #expect(Speed(percent: 50).lowered().percent == 50)
        #expect(!Speed(percent: 150).canRaise && Speed(percent: 150).canLower)
        #expect(!Speed(percent: 50).canLower && Speed(percent: 50).canRaise)
    }

    @Test(arguments: [("75", 75), ("75%", 75), (" 82 % ", 82), ("50", 50), ("125%", 125), ("150", 150), ("126", 126), ("100", 100)])
    func typedValuesInRange(text: String, percent: Int) {
        #expect(Speed(typed: text)?.percent == percent)
    }

    @Test(arguments: ["49", "151", "7.5", "", "abc", "%", "-75", "+75", "1000", "75%%"])
    func typedValuesRefused(text: String) {
        #expect(Speed(typed: text) == nil)
    }

    @Test func folderSuffixAndFactor() {
        #expect(Speed.normal.folderSuffix == "")
        #expect(Speed(percent: 75).folderSuffix == " 75%")
        #expect(Speed(percent: 125).folderSuffix == " 125%")
        #expect(Speed(percent: 75).factor == 0.75)
        #expect(Speed.normal.factor == 1)
    }
}
