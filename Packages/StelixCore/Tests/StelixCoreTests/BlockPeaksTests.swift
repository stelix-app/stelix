// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct BlockPeaksTests {
    @Test func peakOfEachFullBlock() {
        var peaks = BlockPeaks(blockFrames: 4)
        let out = [0.1, 0.5, 0.2, 0.3, 0.9, 0, 0, 0].map { peaks.add(Float($0)) }
        #expect(out == [nil, nil, nil, 0.5, nil, nil, nil, 0.9])
    }
}
