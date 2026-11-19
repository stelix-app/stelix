// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// A fixed-window separation model. Used from a single thread (the ML thread).
public protocol SeparationModel: AnyObject {
    /// Rate at which the model works: 44,100 for Demucs.
    var sampleRate: Double { get }
    /// Frames per window: `Int(7.8 * 44100) = 343980` for Demucs.
    var windowFrames: Int { get }
    /// The output stems, in the order of `separate`.
    var stems: [Stem] { get }
    /// In: `2 × windowFrames` planar samples (L then R). Out: one per stem, same layout and length.
    func separate(planarStereo: [Float]) throws -> [[Float]]
    /// Seconds of one pass on this Mac, measured when the model warmed up; `nil` if not measured.
    var passSeconds: Double? { get }
}

extension SeparationModel {
    public var passSeconds: Double? { nil }
}

/// A piece of stem ready for the timeline, at the device rate.
public struct StemChunk: Sendable {
    /// Input frame (of the ring) the first frame of the piece comes from.
    public let startFrame: Int64
    /// Frames in `data`: the band (`settledFrames`) plus, after it, the provisional band.
    public let frames: Int
    /// The first `settledFrames` are the final band; the rest is provisional and the next step
    /// rewrites it with more context. If the next step arrives late, the provisional part plays meanwhile.
    public let settledFrames: Int
    /// [stem][frame][channel], 2 channels, stems in the order of `SeparationModel.stems`.
    public let data: [Float]

    public init(startFrame: Int64, frames: Int, settledFrames: Int, data: [Float]) {
        self.startFrame = startFrame
        self.frames = frames
        self.settledFrames = settledFrames
        self.data = data
    }
}

public enum StreamingSeparatorError: Error, Equatable {
    /// The window has already been overwritten in the ring: the ML thread fell too far behind.
    case windowLost
    /// The model returned the wrong number of stems or samples.
    case badModelOutput
}

/// The Live separator (the "ML thread"). At every hop it passes the model the last 7.8 s of
/// real audio up to the edge and keeps the band `[edge - lookahead - hop, edge - lookahead)`, where the
/// model already has `lookahead` seconds of context ahead of it. After the band it also returns
/// `[edge - lookahead, edge - guard)` as a provisional band: the next step rewrites it, and if it arrives
/// late that one plays meanwhile. A pass can therefore last up to margin + lookahead - guard.
///
/// The bands of two consecutive steps touch: the first `crossfadeFrames` of a band crossfade
/// linearly with the tail computed by the step before (which the model had seen with less context).
public final class StreamingSeparator {
    public let model: SeparationModel
    public let timing: LiveTiming
    public let deviceRate: Double
    private let resampler: Resampling
    /// The model window in device frames.
    public let windowDeviceFrames: Int

    /// Model frames taken extra per side before going back to the device rate: the converter
    /// filter needs context at the edges.
    static let edgeModelFrames = 1024

    /// Device frames before the edge that do not enter the provisional band: there the filter
    /// of the return to the device rate has no context on the right.
    private let guardFrames: Int
    /// Provisional frames after the band: `[edge - lookahead, edge - guard)`.
    public let provisionalFrames: Int
    private var tail: [Float] = []        // [stem][crossfade][2]
    private var tailStart: Int64 = -1     // device frame `tail` starts from

    public init(model: SeparationModel, timing: LiveTiming, deviceRate: Double, resampler: Resampling) {
        self.model = model
        self.timing = timing
        self.deviceRate = deviceRate
        self.resampler = resampler
        windowDeviceFrames = Int((Double(model.windowFrames) * deviceRate / model.sampleRate).rounded())
        let edge = Int((Double(Self.edgeModelFrames) * deviceRate / model.sampleRate).rounded(.up))
        guardFrames = edge
        provisionalFrames = timing.lookaheadFrames - edge
        precondition(windowDeviceFrames > timing.hopFrames + timing.lookaheadFrames + timing.crossfadeFrames + edge,
                     "the model window does not cover the band")
        precondition(provisionalFrames >= timing.crossfadeFrames, "lookahead too short for the crossfade")
    }

    /// The first useful edge: its band starts at frame 0. Later edges go from `hop` to `hop`,
    /// so the bands cover the whole input without gaps.
    public static func firstEdge(_ timing: LiveTiming) -> Int64 {
        Int64(timing.lookaheadFrames + timing.hopFrames)
    }

    /// One model pass with the window ending at `edge` (ring frame, `≤ writtenFrames`).
    /// `nil` until the first whole band sits above frame 0.
    public func step(ring: SPSCRingBuffer, edge: Int64) throws -> StemChunk? {
        let hop = timing.hopFrames
        let crossfade = timing.crossfadeFrames
        let end = edge - Int64(timing.lookaheadFrames)
        let start = end - Int64(hop)
        guard start >= 0 else { return nil }

        // Window at the device rate, planar, left-padded with zeros until the ring is full.
        let window = windowDeviceFrames
        let windowStart = edge - Int64(window)
        let have = Int(edge - max(0, windowStart))
        let pad = window - have
        let channels = ring.channels
        var raw = [Float](repeating: 0, count: have * channels)
        let copied = raw.withUnsafeMutableBufferPointer { ring.copy(from: edge - Int64(have), frames: have, into: $0.baseAddress!) }
        guard copied else { throw StreamingSeparatorError.windowLost }
        var planar = [Float](repeating: 0, count: 2 * window)
        for f in 0..<have {
            let l = raw[f * channels]
            planar[pad + f] = l
            planar[window + pad + f] = channels > 1 ? raw[f * channels + 1] : l
        }
        raw = []

        let modelRate = model.sampleRate
        let sameRate = modelRate == deviceRate
        let modelIn = sameRate ? planar : Self.fit(resampler.convert(planarStereo: planar, from: deviceRate, to: modelRate),
                                                    frames: model.windowFrames)
        let separated = try model.separate(planarStereo: modelIn)
        guard separated.count == model.stems.count,
              separated.allSatisfy({ $0.count == 2 * model.windowFrames })
        else { throw StreamingSeparatorError.badModelOutput }

        // `[start, end + provisional)` in model time, with a margin per side.
        let provisional = provisionalFrames
        let ratio = modelRate / deviceRate
        let modelStart = Int((Double(start - windowStart) * ratio).rounded()) - Self.edgeModelFrames
        let modelEnd = Int((Double(end + Int64(provisional) - windowStart) * ratio).rounded()) + Self.edgeModelFrames
        let segmentFrames = modelEnd - modelStart
        // Distance, in device frames, between the start of the segment and `start`.
        let offset = Int((Double(start - windowStart) - Double(modelStart) / ratio).rounded())

        let wanted = hop + provisional
        let stems = model.stems.count
        var data = [Float](repeating: 0, count: stems * wanted * 2)
        let modelFrames = model.windowFrames
        for s in 0..<stems {
            var segment = [Float](repeating: 0, count: 2 * segmentFrames)
            let source = separated[s]
            for c in 0..<2 {
                for i in 0..<segmentFrames {
                    let m = modelStart + i
                    if m >= 0 && m < modelFrames { segment[c * segmentFrames + i] = source[c * modelFrames + m] }
                }
            }
            let back = sameRate ? segment : resampler.convert(planarStereo: segment, from: modelRate, to: deviceRate)
            let backFrames = back.count / 2
            for f in 0..<wanted {
                let i = offset + f
                guard i >= 0 && i < backFrames else { continue }
                data[(s * wanted + f) * 2] = back[i]
                data[(s * wanted + f) * 2 + 1] = back[backFrames + i]
            }
        }

        // Join with the tail of the previous step, if the bands touch.
        if tailStart == start && crossfade > 0 {
            for s in 0..<stems {
                for f in 0..<crossfade {
                    let w = Float(f + 1) / Float(crossfade + 1)
                    for c in 0..<2 {
                        let i = (s * wanted + f) * 2 + c
                        data[i] = tail[(s * crossfade + f) * 2 + c] * (1 - w) + data[i] * w
                    }
                }
            }
        }

        // The tail for the join is the start of the provisional band.
        var newTail = [Float](repeating: 0, count: stems * crossfade * 2)
        for s in 0..<stems {
            for f in 0..<crossfade {
                newTail[(s * crossfade + f) * 2] = data[(s * wanted + hop + f) * 2]
                newTail[(s * crossfade + f) * 2 + 1] = data[(s * wanted + hop + f) * 2 + 1]
            }
        }
        tail = newTail
        tailStart = end
        return StemChunk(startFrame: start, frames: wanted, settledFrames: hop, data: data)
    }

    /// Brings every channel of a planar block to exactly `frames` frames (truncates or zero-pads).
    static func fit(_ planar: [Float], frames: Int) -> [Float] {
        let have = planar.count / 2
        if have == frames { return planar }
        var out = [Float](repeating: 0, count: 2 * frames)
        let n = min(have, frames)
        for c in 0..<2 {
            for i in 0..<n { out[c * frames + i] = planar[c * have + i] }
        }
        return out
    }
}
