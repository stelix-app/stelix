// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct PeakLimiterTests {
    private static func sine(frames: Int, amplitude: Float, rate: Double = 48_000) -> [Float] {
        (0..<frames * 2).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0 / 2) / rate)) }
    }

    private static func limited(_ input: [Float]) -> [Float] {
        let limiter = PeakLimiter(sampleRate: 48_000)
        var buffer = input
        buffer.withUnsafeMutableBufferPointer { b in
            var done = 0
            let frames = b.count / 2
            while done < frames {
                let n = min(512, frames - done)
                limiter.process(b.baseAddress! + done * 2, frames: n)
                done += n
            }
        }
        return buffer
    }

    @Test func quietSignalPassesUntouched() {
        let input = Self.sine(frames: 48_000, amplitude: 0.5)
        #expect(Self.limited(input) == input)
    }

    @Test func loudPeaksStayUnderTheCeiling() {
        let out = Self.limited(Self.sine(frames: 48_000, amplitude: 2))
        #expect(out.map(abs).max()! <= PeakLimiter.ceiling + 1e-6)
    }

    @Test func gainComesBack() {
        let loud = Self.sine(frames: 4800, amplitude: 2)
        let quiet = Self.sine(frames: 48_000, amplitude: 0.5)
        let out = Self.limited(loud + quiet)
        // 300 ms after the loud part ends, the quiet sine is back to (almost) its level.
        let from = (4800 + 14_400) * 2
        let peakOut = out[from..<(from + 4800)].map(abs).max()!
        #expect(peakOut >= 0.5 * 0.99)
    }
}
