// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
@testable import StelixCore

/// Test signals and measures for the transpose DSP. Stereo interleaved, 2 channels.
enum AudioTestSignals {
    /// A 2 ms burst of noise under a Hann window, deterministic, at `frame`.
    static func click(frames: Int, at frame: Int, rate: Double, amplitude: Float = 0.5) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        let length = Int(rate * 0.002)
        var seed: UInt32 = 12345
        for i in 0..<length where frame + i < frames {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 8) / Float(1 << 24) * 2 - 1
            let window = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(length - 1)))
            out[(frame + i) * 2] = amplitude * window * noise
            out[(frame + i) * 2 + 1] = amplitude * window * noise
        }
        return out
    }

    /// First frame where the 1 ms moving average of |left| reaches half of its maximum.
    static func onset(_ interleaved: [Float], rate: Double) -> Int? {
        let frames = interleaved.count / 2
        let width = max(1, Int(rate * 0.001))
        var envelope = [Float](repeating: 0, count: frames)
        var sum: Float = 0
        for f in 0..<frames {
            sum += abs(interleaved[f * 2])
            if f >= width { sum -= abs(interleaved[(f - width) * 2]) }
            envelope[f] = sum / Float(width)
        }
        guard let peak = envelope.max(), peak > 1e-6 else { return nil }
        return envelope.firstIndex { $0 >= peak / 2 }
    }

    /// Passes `input` through `body` in blocks of `block` frames.
    static func blocks(_ input: [Float], block: Int,
                       _ body: (UnsafePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) -> [Float] {
        let frames = input.count / 2
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                var done = 0
                while done < frames {
                    let n = min(block, frames - done)
                    body(src.baseAddress! + done * 2, dst.baseAddress! + done * 2, n)
                    done += n
                }
            }
        }
        return output
    }
}

/// A shifter that only delays: latency without any pitch change, to test the chain around it.
final class FakeShifter: PitchShifter, @unchecked Sendable {
    let latencyFrames: Int
    private(set) var calls: [Int] = []
    private var line: [Float]
    private var position = 0

    init(latency: Int) {
        latencyFrames = latency
        line = [Float](repeating: 0, count: max(1, latency) * 2)
    }

    func setSemitones(_ semitones: Int) { calls.append(semitones) }

    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
        guard latencyFrames > 0 else {
            output.update(from: input, count: frames * 2)
            return
        }
        for f in 0..<frames {
            for c in 0..<2 {
                output[f * 2 + c] = line[position * 2 + c]
                line[position * 2 + c] = input[f * 2 + c]
            }
            position = (position + 1) % latencyFrames
        }
    }
}
