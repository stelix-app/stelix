// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct CapturePermissionMemoryTests {
    let suite = "CapturePermissionMemoryTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func startsUnconfirmed() {
        defer { cleanUp() }
        #expect(!CapturePermissionMemory(defaults: defaults).confirmed)
    }

    @Test func zeroLevelsAndPeaksDoNotConfirm() {
        defer { cleanUp() }
        let memory = CapturePermissionMemory(defaults: defaults)
        memory.heard(levels: [.vocals: 0, .drums: 0])
        memory.heard(peaks: [0, 0])
        memory.heard(levels: [:])
        memory.heard(peaks: [])
        #expect(!memory.confirmed)
    }

    @Test func aLevelAboveZeroConfirms() {
        defer { cleanUp() }
        let memory = CapturePermissionMemory(defaults: defaults)
        memory.heard(levels: [.vocals: 0, .drums: 0.02])
        #expect(memory.confirmed)
    }

    @Test func aPeakAboveZeroConfirms() {
        defer { cleanUp() }
        let memory = CapturePermissionMemory(defaults: defaults)
        memory.heard(peaks: [0, 0.001, 0])
        #expect(memory.confirmed)
    }

    @Test func confirmationSurvivesANewInstance() {
        defer { cleanUp() }
        CapturePermissionMemory(defaults: defaults).heard(peaks: [0.5])
        #expect(CapturePermissionMemory(defaults: defaults).confirmed)
        #expect(defaults.bool(forKey: CapturePermissionMemory.key))
    }
}
