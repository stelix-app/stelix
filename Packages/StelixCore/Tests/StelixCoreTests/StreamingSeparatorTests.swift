// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

// MARK: - Fake models

/// Returns the input unchanged on every stem.
final class IdentityModel: SeparationModel {
    let sampleRate = 44_100.0
    let windowFrames: Int
    let stems = Stem.live
    private(set) var calls = 0

    init(windowFrames: Int) {
        self.windowFrames = windowFrames
    }

    func separate(planarStereo: [Float]) throws -> [[Float]] {
        precondition(planarStereo.count == 2 * windowFrames)
        calls += 1
        return stems.map { _ in planarStereo }
    }
}

// MARK: - Live simulator

/// The simulated IOProc: on every callback it writes the input into the ring, delivers the ready chunks
/// to the timeline, plays the timeline with the fixed delay through the mixer and, at every hop, calls `step`.
/// `modelLatency` delays the delivery of every chunk as a slow model would.
final class LiveSimulator {
    let timing: LiveTiming
    let ring: SPSCRingBuffer
    let timeline: StemTimeline
    let mixer: StemMixer
    let separator: StreamingSeparator
    private let modelLatencyFrames: Int64

    private var impulses: [Int64: Float] = [:]
    var constant: Float = 0
    private(set) var output: [Float] = []        // channel 0 of the mixed output
    private(set) var chunks: [StemChunk] = []
    private(set) var underruns = 0
    private(set) var playing = false
    private var pending: [(readyAt: Int64, chunk: StemChunk)] = []
    private var nextEdge: Int64

    convenience init(level: LiveLevel, deviceRate: Double, model: SeparationModel,
                     resampler: Resampling = AVResampler(), modelLatency: Double = 0) {
        self.init(timing: LiveTiming(level: level, deviceRate: deviceRate), model: model,
                  resampler: resampler, modelLatency: modelLatency)
    }

    init(timing: LiveTiming, model: SeparationModel, resampler: Resampling = AVResampler(), modelLatency: Double = 0) {
        let deviceRate = timing.deviceRate
        self.timing = timing
        ring = SPSCRingBuffer(channels: 2, capacityFrames: Int(deviceRate * 12))
        timeline = StemTimeline(stems: model.stems.count, channels: 2, capacityFrames: Int(deviceRate * 8))
        mixer = StemMixer(stems: model.stems, sampleRate: deviceRate)
        // Only one stem on: the identity puts it equal on all of them, so the amplitude stays 1.
        mixer.apply(StemMix(controls: [.other: StemControl(enabled: true, volume: 1)]))
        separator = StreamingSeparator(model: model, timing: timing, deviceRate: deviceRate, resampler: resampler)
        modelLatencyFrames = Int64((modelLatency * deviceRate).rounded())
        nextEdge = StreamingSeparator.firstEdge(timing)
    }

    func injectImpulse(atInputFrame frame: Int64, amplitude: Float = 1) {
        impulses[frame] = amplitude
    }

    func run(callbacks: Int, framesPerCallback frames: Int) {
        var input = [Float](repeating: 0, count: frames * 2)
        var stems = [Float](repeating: 0, count: timeline.stems * frames * 2)
        var out = [Float](repeating: 0, count: frames * 2)
        let delay = Int64(timing.delayFrames)
        for _ in 0..<callbacks {
            let start = ring.writtenFrames
            for f in 0..<frames {
                let v = constant + (impulses[start + Int64(f)] ?? 0)
                input[f * 2] = v
                input[f * 2 + 1] = v
            }
            ring.write(input, frames: frames)
            let written = ring.writtenFrames

            while let first = pending.first, first.readyAt <= written {
                pending.removeFirst()
                first.chunk.data.withUnsafeBufferPointer {
                    timeline.write(startFrame: first.chunk.startFrame, frames: first.chunk.frames, data: $0.baseAddress!)
                }
            }
            // Like the LiveEngine: it plays when the ring has the delay and the timeline covers one hop
            // beyond the playback point.
            if !playing && start >= delay && timeline.availableUpTo >= start - delay + Int64(timing.hopFrames) {
                playing = true
                mixer.setMaster(1)
            }
            let got = timeline.read(at: start - delay, frames: frames, into: &stems)
            if playing && got < frames { underruns += 1 }
            mixer.render(stemFrames: stems, frames: frames, channels: 2, out: &out, outChannels: 2)
            for f in 0..<frames { output.append(out[f * 2]) }

            while written >= nextEdge {
                if let chunk = try! separator.step(ring: ring, edge: nextEdge) {
                    chunks.append(chunk)
                    pending.append((written + modelLatencyFrames, chunk))
                }
                nextEdge += Int64(timing.hopFrames)
            }
        }
    }

    /// Output frame with the highest peak.
    var outputImpulseFrame: Int64 {
        var best = 0
        for i in output.indices where abs(output[i]) > abs(output[best]) { best = i }
        return Int64(best)
    }
}

// MARK: - Test

struct StreamingSeparatorTests {
    /// 1 s: the window must cover hop + lookahead + crossfade + 1024 frames of margin.
    static let window = 44_100

    @Test func endToEndShiftEqualsDeclaredDelay() throws {
        let sim = LiveSimulator(level: .base, deviceRate: 44100, model: IdentityModel(windowFrames: Self.window))
        sim.injectImpulse(atInputFrame: 20_000)
        sim.run(callbacks: 200, framesPerCallback: 512)
        #expect(sim.outputImpulseFrame - 20_000 == Int64(sim.timing.delayFrames))
        #expect(sim.underruns == 0)
    }

    @Test func impulseAppearsAtSameInputFrame() throws {
        let sim = LiveSimulator(level: .base, deviceRate: 44100, model: IdentityModel(windowFrames: Self.window))
        sim.injectImpulse(atInputFrame: 20_000)
        sim.run(callbacks: 200, framesPerCallback: 512)
        let chunk = try #require(sim.chunks.first { $0.startFrame <= 20_000 && 20_000 < $0.startFrame + Int64($0.settledFrames) })
        let stems = chunk.data.count / (chunk.frames * 2)
        #expect(stems == 4)
        for s in 0..<stems {
            var peak = 0
            for f in 0..<chunk.frames where abs(chunk.data[(s * chunk.frames + f) * 2]) > abs(chunk.data[(s * chunk.frames + peak) * 2]) {
                peak = f
            }
            #expect(chunk.startFrame + Int64(peak) == 20_000)
            #expect(abs(chunk.data[(s * chunk.frames + peak) * 2] - 1) < 1e-6)
            #expect(abs(chunk.data[(s * chunk.frames + peak) * 2 + 1] - 1) < 1e-6)
        }
    }

    @Test func constantInputHasNoSeams() throws {
        let sim = LiveSimulator(level: .base, deviceRate: 44100, model: IdentityModel(windowFrames: Self.window))
        sim.constant = 0.5
        sim.run(callbacks: 400, framesPerCallback: 512)
        #expect(sim.chunks.count >= 11)
        for (a, b) in zip(sim.chunks, sim.chunks.dropFirst()) {
            #expect(b.startFrame == a.startFrame + Int64(a.settledFrames))   // contiguous bands, one seam each
        }
        var worst: Float = 0
        for chunk in sim.chunks { for v in chunk.data { worst = max(worst, abs(v - 0.5)) } }
        #expect(worst < 1e-6)
    }

    @Test func resampledImpulseWithinTwoFrames() throws {
        let sim = LiveSimulator(level: .base, deviceRate: 48_000, model: IdentityModel(windowFrames: Self.window))
        sim.injectImpulse(atInputFrame: 20_000)
        sim.run(callbacks: 200, framesPerCallback: 512)
        let shift = sim.outputImpulseFrame - 20_000
        #expect(abs(shift - Int64(sim.timing.delayFrames)) <= 2)
        #expect(sim.underruns == 0)
    }

    /// Rates of cards we have not tried (24k of some docks, 88.2k and 96k of audio cards):
    /// same declared delay, within 2 frames, and no underrun. They are ~1.7 s of synchronous computation:
    /// they run in series on a GCD queue, because on the cooperative pool they would slow the tests that
    /// measure short times (EngineStopTests).
    @Test(.serialized, arguments: [24_000.0, 32_000.0, 88_200.0, 96_000.0])
    func otherDeviceRatesKeepTheDeclaredDelay(rate: Double) async throws {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let sim = LiveSimulator(level: .base, deviceRate: rate, model: IdentityModel(windowFrames: Self.window))
                sim.injectImpulse(atInputFrame: Int64(rate / 2))
                sim.run(callbacks: Int(rate * 3 / 512), framesPerCallback: 512)
                continuation.resume(returning: (shift: sim.outputImpulseFrame - Int64(rate / 2),
                                                delay: Int64(sim.timing.delayFrames),
                                                playing: sim.playing, underruns: sim.underruns))
            }
        }
        #expect(abs(result.shift - result.delay) <= 2)
        #expect(result.playing)
        #expect(result.underruns == 0)
    }

    // MARK: Margin (found in review)

    /// A model that takes less than the margin gives no underrun at Intermediate.
    @Test func modelWithinMarginHasNoUnderruns() throws {
        let margin = LiveLevel.intermediate.margin
        let sim = LiveSimulator(level: .intermediate, deviceRate: 48_000, model: IdentityModel(windowFrames: Self.window),
                                modelLatency: margin - 0.05)
        sim.constant = 0.5
        sim.run(callbacks: 600, framesPerCallback: 512)
        #expect(sim.playing)
        #expect(sim.underruns == 0)
    }

    /// Slower than the margin but within margin + lookahead: the provisional band of the previous step plays.
    @Test func modelSlowerThanMarginButWithinLookaheadHasNoUnderruns() throws {
        let level = LiveLevel.intermediate
        let sim = LiveSimulator(level: level, deviceRate: 48_000, model: IdentityModel(windowFrames: Self.window),
                                modelLatency: level.margin + level.lookahead - 0.1)   // guard 23 ms and a 512-frame callback
        sim.constant = 0.5
        sim.run(callbacks: 600, framesPerCallback: 512)
        #expect(sim.playing)
        #expect(sim.underruns == 0)
    }

    /// Beyond margin + lookahead it underruns: this is the rule that fixes margin and lookahead.
    @Test func modelSlowerThanMarginPlusLookaheadUnderruns() throws {
        let level = LiveLevel.intermediate
        let sim = LiveSimulator(level: level, deviceRate: 48_000, model: IdentityModel(windowFrames: Self.window),
                                modelLatency: level.margin + level.lookahead + 0.05)
        sim.constant = 0.5
        sim.run(callbacks: 600, framesPerCallback: 512)
        // Too slow: it either never starts (the timeline does not cover the playback point: the LiveEngine
        // gives up with LiveTiming.modelIsStalled) or underruns. Never clean.
        #expect(!sim.playing || sim.underruns > 0)
    }

    @Test func noChunkBeforeFirstFullBand() throws {
        let model = IdentityModel(windowFrames: Self.window)
        let timing = LiveTiming(level: .base, deviceRate: 44_100)
        let separator = StreamingSeparator(model: model, timing: timing, deviceRate: 44_100, resampler: AVResampler())
        let ring = SPSCRingBuffer(channels: 2, capacityFrames: 44_100 * 12)
        let frames = timing.hopFrames + timing.lookaheadFrames
        ring.write([Float](repeating: 0.1, count: frames * 2), frames: frames)
        #expect(try separator.step(ring: ring, edge: Int64(frames - 1)) == nil)
        #expect(model.calls == 0)
        let chunk = try #require(try separator.step(ring: ring, edge: Int64(frames)))
        #expect(chunk.startFrame == 0)
        #expect(chunk.settledFrames == timing.hopFrames)
        // After the band, the rest of the window almost up to the edge as a provisional band.
        #expect(chunk.frames > timing.hopFrames + timing.lookaheadFrames / 2)
        #expect(chunk.frames <= timing.hopFrames + timing.lookaheadFrames)
    }

    @Test func monoRingIsDuplicatedOnBothChannels() throws {
        let model = IdentityModel(windowFrames: Self.window)
        let timing = LiveTiming(level: .base, deviceRate: 44_100)
        let separator = StreamingSeparator(model: model, timing: timing, deviceRate: 44_100, resampler: AVResampler())
        let ring = SPSCRingBuffer(channels: 1, capacityFrames: 44_100 * 12)
        let frames = timing.hopFrames + timing.lookaheadFrames
        ring.write([Float](repeating: 0.25, count: frames), frames: frames)
        let chunk = try #require(try separator.step(ring: ring, edge: Int64(frames)))
        #expect(chunk.data.allSatisfy { abs($0 - 0.25) < 1e-6 })
    }
}

extension StemChunk: Equatable {
    public static func == (a: StemChunk, b: StemChunk) -> Bool {
        a.startFrame == b.startFrame && a.frames == b.frames && a.settledFrames == b.settledFrames && a.data == b.data
    }
}
