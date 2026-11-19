// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The peak of every block of `blockFrames` samples, for the live recording waveform.
public struct BlockPeaks: Sendable {
    private let blockFrames: Int
    private var count = 0
    private var peak: Float = 0

    public init(blockFrames: Int) {
        self.blockFrames = max(1, blockFrames)
    }

    /// `magnitude` is already an absolute value. Returns the peak when a block closes.
    public mutating func add(_ magnitude: Float) -> Float? {
        peak = max(peak, magnitude)
        count += 1
        guard count == blockFrames else { return nil }
        defer { count = 0; peak = 0 }
        return peak
    }
}
