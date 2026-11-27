// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// A pure delay of `frames` frames, stereo interleaved: the drums wait for the transposed stems with it.
/// No allocation after `init`, no lock: `process` runs in the IOProc.
public final class FixedDelay: @unchecked Sendable {
    private let frames: Int
    private let line: UnsafeMutablePointer<Float>
    private var position = 0

    public init(frames: Int) {
        self.frames = max(0, frames)
        line = .allocate(capacity: max(1, self.frames) * 2)
        line.initialize(repeating: 0, count: max(1, self.frames) * 2)
    }

    deinit { line.deallocate() }

    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames count: Int) {
        guard frames > 0 else {
            output.update(from: input, count: count * 2)
            return
        }
        for f in 0..<count {
            let slot = line + position * 2
            let left = input[f * 2], right = input[f * 2 + 1]
            output[f * 2] = slot[0]
            output[f * 2 + 1] = slot[1]
            slot[0] = left
            slot[1] = right
            position += 1
            if position == frames { position = 0 }
        }
    }
}
