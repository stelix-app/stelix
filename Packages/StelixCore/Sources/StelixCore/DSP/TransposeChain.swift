// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The transposed path of the Live: the rest through the shifter, the drums through a pure delay of the
/// same latency (they are never transposed, they only wait), summed. Silent for the shifter's latency,
/// then in with a 40 ms ramp, so entering from 0 does not click; then the limiter. Everything is
/// allocated in `init`: `process` and `setSemitones` run in the IOProc. Stereo interleaved, at most
/// `maxFrames` frames per call.
public final class TransposeChain: @unchecked Sendable {
    public static let maxFrames = 4096
    static let rampSeconds = 0.040

    public let latencyFrames: Int
    private let shifter: PitchShifter
    private let drumsDelay: FixedDelay
    private let limiter: PeakLimiter
    private let entry: GainSmoother
    private let shifted: UnsafeMutablePointer<Float>
    private let delayed: UnsafeMutablePointer<Float>
    private var processed = 0
    private var semitones: Int

    public init(shifter: PitchShifter, sampleRate: Double, semitones: Int) {
        self.shifter = shifter
        latencyFrames = shifter.latencyFrames
        drumsDelay = FixedDelay(frames: shifter.latencyFrames)
        limiter = PeakLimiter(sampleRate: sampleRate)
        entry = GainSmoother(sampleRate: sampleRate, rampSeconds: Self.rampSeconds, initial: 0)
        shifted = .allocate(capacity: Self.maxFrames * 2)
        shifted.initialize(repeating: 0, count: Self.maxFrames * 2)
        delayed = .allocate(capacity: Self.maxFrames * 2)
        delayed.initialize(repeating: 0, count: Self.maxFrames * 2)
        self.semitones = semitones
        shifter.setSemitones(semitones)
    }

    /// With Apple's AUNewTimePitch.
    public convenience init(sampleRate: Double, semitones: Int) throws(EngineFailure) {
        self.init(shifter: try AppleTimePitch(sampleRate: sampleRate), sampleRate: sampleRate, semitones: semitones)
    }

    deinit {
        shifted.deallocate()
        delayed.deallocate()
    }

    /// Nothing if unchanged.
    public func setSemitones(_ value: Int) {
        guard value != semitones else { return }
        semitones = value
        shifter.setSemitones(value)
    }

    public func process(drums: UnsafePointer<Float>, rest: UnsafePointer<Float>, frames: Int,
                        into out: UnsafeMutablePointer<Float>) {
        let frames = min(frames, Self.maxFrames)
        shifter.process(rest, shifted, frames: frames)
        drumsDelay.process(drums, delayed, frames: frames)
        for f in 0..<frames {
            if processed == latencyFrames { entry.setTarget(1) }
            if processed <= latencyFrames { processed += 1 }
            let g = entry.next()
            out[f * 2] = g * (shifted[f * 2] + delayed[f * 2])
            out[f * 2 + 1] = g * (shifted[f * 2 + 1] + delayed[f * 2 + 1])
        }
        limiter.process(out, frames: frames)
    }
}

/// What a change of transpose asks the Live to do: from 0 the chain enters, to 0 it leaves, between two
/// values only the pitch changes.
public enum TransposeTransition: Equatable, Sendable {
    case none
    case retune(Int)
    case enter(Int)
    case leave

    public init(from old: Transpose, to new: Transpose) {
        switch (old.isOff, new.isOff) {
        case (true, true): self = .none
        case (true, false): self = .enter(new.semitones)
        case (false, true): self = .leave
        case (false, false): self = old == new ? .none : .retune(new.semitones)
        }
    }
}
