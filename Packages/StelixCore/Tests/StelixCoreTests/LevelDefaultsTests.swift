// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

@Suite struct LevelDefaultsTests {
    @Test func freshInstallStudioStartsFromBase() {
        #expect(StudioLevel.initial(stored: nil) == .base)
    }

    @Test func freshInstallLiveStaysOnIntermediate() {
        #expect(LiveLevel.initial(stored: nil) == .intermediate)
    }

    @Test func savedPreferenceIsKept() {
        #expect(StudioLevel.initial(stored: "intermediate") == .intermediate)
        #expect(StudioLevel.initial(stored: "pro") == .pro)
        #expect(LiveLevel.initial(stored: "base") == .base)
    }

    @Test func unknownStoredValueFallsBackToDefault() {
        #expect(StudioLevel.initial(stored: "ultra") == .base)
        #expect(LiveLevel.initial(stored: "") == .intermediate)
    }
}
