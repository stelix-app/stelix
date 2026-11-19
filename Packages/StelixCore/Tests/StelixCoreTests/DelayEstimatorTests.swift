// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct DelayEstimatorTests {
    private static func noise(_ n: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 2000 - 0.5
        }
    }

    private static func delayed(_ x: [Float], by lag: Int, gain: Float = 1) -> [Float] {
        (0..<x.count).map { $0 >= lag ? gain * x[$0 - lag] : 0 }
    }

    @Test func findsLagOfDelayedNoise() {
        let x = Self.noise(48_000 * 6, seed: 7)
        let y = Self.delayed(x, by: 12_345, gain: 0.7)
        let found = DelayEstimator.lag(reference: x, delayed: y, maxLag: 48_000 * 4)
        #expect(found?.lag == 12_345)
        #expect((found?.score ?? 0) > 0.9)
    }

    /// The test click track: one click every 2 s, a delay of about 1 s, a little noise.
    @Test func findsLagOfClickTrack() {
        let rate = 48_000, n = rate * 6
        var x = [Float](repeating: 0, count: n)
        for k in stride(from: rate / 3, to: n, by: 2 * rate) {
            for i in 0..<48 where k + i < n { x[k + i] = Float(sin(Double(i) * 0.6)) * Float(1 - Double(i) / 48) }
        }
        let noise = Self.noise(n, seed: 3)
        var y = Self.delayed(x, by: 48_017)
        for i in 0..<n { y[i] += 0.01 * noise[i] }
        #expect(DelayEstimator.lag(reference: x, delayed: y, maxLag: rate * 4)?.lag == 48_017)
    }

    @Test func silenceGivesNothing() {
        let zeros = [Float](repeating: 0, count: 10_000)
        #expect(DelayEstimator.lag(reference: zeros, delayed: zeros, maxLag: 5_000) == nil)
    }
}
