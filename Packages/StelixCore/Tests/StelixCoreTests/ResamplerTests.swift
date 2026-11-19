// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct ResamplerTests {
    private static func sine(frames: Int, rate: Double, hz: Double) -> [Float] {
        let l = (0..<frames).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
        let r = (0..<frames).map { Float(0.5 * cos(2 * .pi * hz * Double($0) / rate)) }
        return l + r
    }

    @Test func roundTripSineBelowMinus60dB() {
        let frames = 48_000
        let input = Self.sine(frames: frames, rate: 48_000, hz: 1_000)
        let resampler = AVResampler()
        let down = resampler.convert(planarStereo: input, from: 48_000, to: 44_100)
        #expect(down.count == 2 * 44_100)
        let back = resampler.convert(planarStereo: down, from: 44_100, to: 48_000)
        #expect(back.count == input.count)

        var err = 0.0, sig = 0.0, n = 0
        for c in 0..<2 {
            for f in (frames / 10)..<(frames * 9 / 10) {
                let i = c * frames + f
                err += Double((back[i] - input[i]) * (back[i] - input[i]))
                sig += Double(input[i] * input[i])
                n += 1
            }
        }
        let db = 10 * log10(err / sig)
        #expect(db < -60, "error \(db) dB")
    }

    @Test func sameRateIsACopy() {
        let input = Self.sine(frames: 1_000, rate: 44_100, hz: 440)
        #expect(AVResampler().convert(planarStereo: input, from: 44_100, to: 44_100) == input)
    }

    @Test func lengthFollowsRatio() {
        let input = [Float](repeating: 0.1, count: 2 * 374_400)
        let out = AVResampler().convert(planarStereo: input, from: 48_000, to: 44_100)
        #expect(out.count == 2 * 343_980)
    }
}
