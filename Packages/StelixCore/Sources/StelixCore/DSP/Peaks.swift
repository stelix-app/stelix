// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Accelerate

/// Peaks for the Studio waveform: for each bin the maximum of |x| over the two channels, clipped to 1.
public enum Peaks {
    /// The height (0...1) at which the waveform draws `peak`: its square root.
    /// With the linear scale a separated stem (peaks of 0.2-0.5) filled a fifth to half of the row
    /// and a soft guitar was a flat line. A decibel scale (floor −40 or −30 dB) brought almost every
    /// stem of a mastered song to the top, as if it clipped. The square root shows the soft instruments
    /// and keeps the loud ones higher (compared on real stems, 18/11). Only the drawing uses it:
    /// the peaks stay linear.
    public static func displayLevel(_ peak: Float) -> Float {
        min(max(peak, 0), 1).squareRoot()
    }

    public static func compute(planarStereo: [Float], frames: Int, bins: Int = 600) -> [Float] {
        guard bins > 0 else { return [] }
        guard frames > 0, planarStereo.count >= 2 * frames else { return [Float](repeating: 0, count: bins) }
        return planarStereo.withUnsafeBufferPointer { samples in
            let base = samples.baseAddress!
            return (0..<bins).map { bin in
                // With fewer frames than bins, each bin takes the nearest sample.
                let start = bin * frames / bins
                let end = min(frames, max(start + 1, (bin + 1) * frames / bins))
                let count = vDSP_Length(end - start)
                var left: Float = 0
                var right: Float = 0
                vDSP_maxmgv(base + start, 1, &left, count)
                vDSP_maxmgv(base + frames + start, 1, &right, count)
                return min(1, max(left, right))
            }
        }
    }
}
