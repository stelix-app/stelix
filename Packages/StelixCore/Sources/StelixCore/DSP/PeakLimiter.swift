// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// The transposed Live can peak above the original (measured on 26/11: up to +4 dB with AUNewTimePitch at
/// +3), and the converter would clip. Stereo-linked, no lookahead (it would add delay): the gain drops at
/// once to keep a frame under `ceiling`, then comes back with an exponential release. Under the ceiling,
/// with the gain back at 1, the samples are not touched. No allocation, no lock: it runs in the IOProc.
public final class PeakLimiter: @unchecked Sendable {
    /// -0.3 dBFS.
    public static let ceiling: Float = 0.966
    public static let releaseSeconds = 0.050

    private let release: Float
    private var gain: Float = 1

    public init(sampleRate: Double) {
        release = Float(1 - exp(-1 / (sampleRate * Self.releaseSeconds)))
    }

    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for f in 0..<frames {
            let left = buffer[f * 2], right = buffer[f * 2 + 1]
            // The release would approach 1 forever and stop one float short of it: it snaps there.
            if gain < 1 { gain = 1 - gain < 1e-5 ? 1 : gain + (1 - gain) * release }
            let peak = max(abs(left), abs(right))
            if peak * gain > Self.ceiling { gain = Self.ceiling / peak }
            if gain < 1 {
                buffer[f * 2] = left * gain
                buffer[f * 2 + 1] = right * gain
            }
        }
    }
}
