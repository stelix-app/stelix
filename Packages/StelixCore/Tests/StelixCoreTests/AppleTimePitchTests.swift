// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct AppleTimePitchTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func latencyIs4096Frames(rate: Double) throws {
        #expect(try AppleTimePitch(sampleRate: rate).latencyFrames == 4096)
    }

    @Test func plusTwelveDoublesTheFrequency() throws {
        let rate = 48_000.0
        let shifter = try AppleTimePitch(sampleRate: rate)
        shifter.setSemitones(12)
        let frames = Int(rate) * 2
        let input = (0..<frames * 2).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0 / 2) / rate)) }
        let output = AudioTestSignals.blocks(input, block: 512) { shifter.process($0, $1, frames: $2) }
        // Upward zero crossings of the left channel in the second half, steady.
        let half = frames / 2
        var crossings = 0
        for f in (half + 1)..<frames where output[(f - 1) * 2] < 0 && output[f * 2] >= 0 { crossings += 1 }
        let hz = Double(crossings) / (Double(frames - half) / rate)
        #expect(abs(hz / 880 - 1) < 0.02, "\(hz) Hz")
    }
}
