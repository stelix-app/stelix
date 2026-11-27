// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct StemMixerSplitTests {
    static let drums = Stem.live.firstIndex(of: .drums)!

    /// [stem][frame][channel], deterministic.
    private static func stems(frames: Int, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<Stem.live.count * frames * 2).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
    }

    private static func mixer() -> StemMixer {
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.volume = 0.4
        let mixer = StemMixer(stems: Stem.live, sampleRate: 48_000)
        mixer.apply(mix)
        mixer.setMaster(1)
        return mixer
    }

    /// Two mixers with the same history: one renders as today, the other splits, sums and finishes.
    /// Three blocks of 1024 frames: the master ramp (40 ms, 1920 frames) is inside them.
    @Test(arguments: [1, 2, 3])
    func splitThenFinishEqualsRender(outChannels: Int) {
        let a = Self.mixer(), b = Self.mixer()
        let frames = 1024
        var split = [Float](repeating: 0, count: frames * 2)
        var rest = [Float](repeating: 0, count: frames * 2)
        var sum = [Float](repeating: 0, count: frames * 2)
        for block in 0..<3 {
            let stems = Self.stems(frames: frames, seed: UInt32(block + 1))
            var expected = [Float](repeating: 0, count: frames * outChannels)
            var got = [Float](repeating: 1, count: frames * outChannels)
            stems.withUnsafeBufferPointer { s in
                expected.withUnsafeMutableBufferPointer {
                    a.render(stemFrames: s.baseAddress!, frames: frames, channels: 2, out: $0.baseAddress!, outChannels: outChannels)
                }
                split.withUnsafeMutableBufferPointer { sp in
                    rest.withUnsafeMutableBufferPointer { r in
                        b.renderSplit(stemFrames: s.baseAddress!, frames: frames, channels: 2, splitStem: Self.drums,
                                      split: sp.baseAddress!, rest: r.baseAddress!)
                    }
                }
            }
            for i in 0..<(frames * 2) { sum[i] = split[i] + rest[i] }
            sum.withUnsafeBufferPointer { s in
                got.withUnsafeMutableBufferPointer {
                    b.finish(s.baseAddress!, frames: frames, out: $0.baseAddress!, outChannels: outChannels)
                }
            }
            #expect(zip(expected, got).allSatisfy { abs($0 - $1) <= 1e-6 }, "block \(block)")
        }
    }

    @Test func splitPutsOnlyDrumsInSplit() {
        let mixer = Self.mixer()
        let frames = 4800
        var values = [Float](repeating: 0.1, count: Stem.live.count * frames * 2)
        for i in 0..<(frames * 2) { values[Self.drums * frames * 2 + i] = 0.3 }
        var split = [Float](repeating: 0, count: frames * 2)
        var rest = [Float](repeating: 0, count: frames * 2)
        values.withUnsafeBufferPointer { s in
            split.withUnsafeMutableBufferPointer { sp in
                rest.withUnsafeMutableBufferPointer { r in
                    mixer.renderSplit(stemFrames: s.baseAddress!, frames: frames, channels: 2, splitStem: Self.drums,
                                      split: sp.baseAddress!, rest: r.baseAddress!)
                }
            }
        }
        // Settled stem gains (15 ms), no master in the split: vocals 0.1 + bass 0.4 × 0.1 + other 0.1.
        #expect(abs(split[(frames - 1) * 2] - 0.3) < 1e-6)
        #expect(abs(rest[(frames - 1) * 2] - 0.24) < 1e-6)
    }
}
