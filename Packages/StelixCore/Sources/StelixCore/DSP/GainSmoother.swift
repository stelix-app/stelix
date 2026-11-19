// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Synchronization

/// A gain that goes toward its target with a linear ramp.
///
/// `setTarget` can be called from any thread (it only writes an Atomic with the Float bits). `next` and
/// `isSettled` belong to the audio thread: the ramp state is its own and is not protected.
public final class GainSmoother: @unchecked Sendable {
    private let rampFrames: Int
    private let targetBits: Atomic<UInt32>
    private var current: Float
    private var rampTarget: Float
    private var step: Float = 0
    private var remaining = 0

    /// Ramps used by Stelix: 0.015 s for stems, 0.040 s for the master.
    public init(sampleRate: Double, rampSeconds: Double, initial: Float) {
        rampFrames = max(1, Int((sampleRate * rampSeconds).rounded()))
        targetBits = Atomic(initial.bitPattern)
        current = initial
        rampTarget = initial
    }

    public func setTarget(_ value: Float) {
        targetBits.store(value.bitPattern, ordering: .relaxed)
    }

    /// One value per frame. A new target restarts the ramp from the current value, always
    /// `rampFrames` long; the last step equals the target exactly.
    @inline(__always)
    public func next() -> Float {
        let target = Float(bitPattern: targetBits.load(ordering: .relaxed))
        if target != rampTarget {
            rampTarget = target
            remaining = rampFrames
            step = (target - current) / Float(rampFrames)
        }
        if remaining > 0 {
            remaining -= 1
            current = remaining == 0 ? rampTarget : current + step
        }
        return current
    }

    public var isSettled: Bool {
        remaining == 0 && current == Float(bitPattern: targetBits.load(ordering: .relaxed))
    }
}

/// Sums the stems with their smoothed gains and the master. No allocation after `init`:
/// `render` is called from the IOProc.
public struct StemMixer: @unchecked Sendable {
    public let stems: [Stem]
    private let gains: [GainSmoother]
    /// The same gains without reference counting: reading `gains[s]` in the frame loop
    /// cost one retain and one release per frame and per stem (seen in the disassembly), atomic,
    /// inside the IOProc. `gains` keeps them alive.
    private let gainRefs: [Unmanaged<GainSmoother>]
    private let master: GainSmoother
    private let gap: GainSmoother
    private let gapRampFrames: Int

    /// Stems and master start at 0: nothing plays until `apply` and `setMaster` arrive.
    public init(stems: [Stem], sampleRate: Double) {
        self.stems = stems
        gains = stems.map { _ in GainSmoother(sampleRate: sampleRate, rampSeconds: 0.015, initial: 0) }
        gainRefs = gains.map { Unmanaged.passUnretained($0) }
        master = GainSmoother(sampleRate: sampleRate, rampSeconds: 0.040, initial: 0)
        gap = GainSmoother(sampleRate: sampleRate, rampSeconds: Self.gapRampSeconds, initial: 1)
        gapRampFrames = max(1, Int((sampleRate * Self.gapRampSeconds).rounded()))
    }

    static let gapRampSeconds = 0.010

    public func apply(_ mix: StemMix) {
        for (gain, stem) in zip(gains, stems) { gain.setTarget(mix.effectiveGain(stem)) }
    }

    /// Fade in o out da 40 ms.
    public func setMaster(_ value: Float) {
        master.setTarget(value)
    }

    /// Against the click of an underrun: before every block the IOProc says how many stem frames are
    /// ready from the playback point. If they run out within the block plus a 10 ms ramp, the sound
    /// falls to zero in time; when they come back, it rises again with the same ramp.
    public func guardAgainstGap(framesAhead: Int64, frames: Int) {
        gap.setTarget(framesAhead >= Int64(frames + gapRampFrames) ? 1 : 0)
    }

    /// `stemFrames`: [stem][frame][channel], stems in the order of `stems`. `out` is interleaved with
    /// `outChannels` channels: stems go on the first `channels` (usually 2), the others stay at 0.
    /// With a mono output the channel average is written.
    public func render(stemFrames: UnsafePointer<Float>, frames: Int, channels: Int,
                       out: UnsafeMutablePointer<Float>, outChannels: Int) {
        let stemStride = frames * channels
        let mapped = min(channels, outChannels)
        let mono = outChannels == 1 && channels > 1
        gainRefs.withUnsafeBufferPointer { gains in
            for f in 0..<frames {
                let m = master.next() * gap.next()
                let frameOut = out + f * outChannels
                for c in 0..<outChannels { frameOut[c] = 0 }
                for s in 0..<gains.count {
                    let g = gains[s]._withUnsafeGuaranteedRef { $0.next() } * m
                    let src = stemFrames + s * stemStride + f * channels
                    if mono {
                        var sum: Float = 0
                        for c in 0..<channels { sum += src[c] }
                        frameOut[0] += g * sum / Float(channels)
                    } else {
                        for c in 0..<mapped { frameOut[c] += g * src[c] }
                    }
                }
            }
        }
    }
}
