// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct StemsResultKeyTests {
    static let am = MusicalKey(pitchClass: 9, mode: .minor), c = MusicalKey(pitchClass: 0, mode: .major)

    private static func result(peak: Float, scan: KeyScan?) -> StemsResult {
        StemsResult(folder: "/s", files: [:], duration: 60,
                    waveforms: [.vocals: Array(repeating: peak, count: 600)], keyScan: scan)
    }

    /// Windows 0-4 in A minor, 6-10 in C (window 5 unsure): two sections with a gap between them.
    private static let scan = KeyScan(duration: 60, windows: (0..<11).map { index in
        KeyWindow(index: index, key: index < 5 ? am : index == 5 ? nil : c)
    })

    @Test func keyAtTimeUsesTheSureSections() {
        let result = Self.result(peak: 0.5, scan: Self.scan)
        #expect(result.key(at: 10) == Self.am)
        #expect(result.key(at: 29) == nil)
        #expect(result.key(at: 45) == Self.c)
    }

    @Test func keyOnSilenceIsNil() {
        #expect(Self.result(peak: 0, scan: Self.scan).key(at: 10) == nil)
    }

    @Test func noScanGivesNil() {
        #expect(Self.result(peak: 0.5, scan: nil).key(at: 10) == nil)
    }
}
