// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct FixedDelayTests {
    @Test func delaysByExactlyTheFrames() {
        var input = [Float](repeating: 0, count: 10_000 * 2)
        input[0] = 1
        input[1] = 0.5
        let delay = FixedDelay(frames: 4096)
        var done = 0
        let output = AudioTestSignals.blocks(input, block: 512) { src, dst, n in
            // Uneven blocks too: 512 then 37.
            let m = done % 2 == 0 ? n : min(n, 37)
            delay.process(src, dst, frames: m)
            if m < n { delay.process(src + m * 2, dst + m * 2, frames: n - m) }
            done += 1
        }
        #expect(output[4096 * 2] == 1 && output[4096 * 2 + 1] == 0.5)
        #expect(output.enumerated().allSatisfy { $0.offset / 2 == 4096 || $0.element == 0 })
    }

    @Test func zeroFramesIsACopy() {
        let input = AudioTestSignals.click(frames: 2000, at: 100, rate: 48_000)
        let delay = FixedDelay(frames: 0)
        #expect(AudioTestSignals.blocks(input, block: 512) { delay.process($0, $1, frames: $2) } == input)
    }
}
