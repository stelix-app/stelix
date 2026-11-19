// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct PeaksTests {
    @Test func binsCountAndRange() {
        let frames = 44_100
        var left = [Float](repeating: 0.1, count: frames)
        let right = [Float](repeating: -0.2, count: frames)
        left[frames / 2] = -1.5   // out of range: must be clipped to 1
        let peaks = Peaks.compute(planarStereo: left + right, frames: frames, bins: 600)
        #expect(peaks.count == 600)
        #expect(peaks.allSatisfy { (0...1).contains($0) })
        #expect(peaks[300] == 1)
        // The maximum between the two channels, in absolute value.
        #expect(abs(peaks[0] - 0.2) < 1e-6)
    }

    @Test func fewerFramesThanBins() {
        let peaks = Peaks.compute(planarStereo: [0.5, 0.25, 0, 0], frames: 2, bins: 600)
        #expect(peaks.count == 600)
        #expect(peaks.first == 0.5)
        #expect(peaks.last == 0.25)
    }

    /// The waveform height is the square root of the peak.
    @Test func displayLevelIsSquareRoot() {
        #expect(Peaks.displayLevel(1) == 1)
        #expect(Peaks.displayLevel(0) == 0)
        #expect(Peaks.displayLevel(0.25) == 0.5)
        #expect(abs(Peaks.displayLevel(0.01) - 0.1) < 1e-6)
        #expect(Peaks.displayLevel(1.5) == 1)  // clipped
        #expect(Peaks.displayLevel(-0.5) == 0)
        // Monotonic: a louder peak is never lower.
        let levels = stride(from: Float(0), through: 1, by: 0.01).map(Peaks.displayLevel)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func emptyIsZeros() {
        #expect(Peaks.compute(planarStereo: [], frames: 0, bins: 10) == [Float](repeating: 0, count: 10))
    }
}
