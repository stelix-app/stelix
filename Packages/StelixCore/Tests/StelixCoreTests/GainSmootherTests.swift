// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct GainSmootherTests {
    @Test func rampReachesTargetIn15ms() {
        let g = GainSmoother(sampleRate: 48_000, rampSeconds: 0.015, initial: 0)
        g.setTarget(1)
        var values: [Float] = []
        for _ in 0..<720 { values.append(g.next()) }
        #expect(abs(values[719] - 1) <= 1e-6)
        #expect(values[718] < 1)
        #expect(abs(values[359] - 0.5) < 0.01)            // linear ramp: halfway it is about half
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(g.isSettled)
        #expect(g.next() == 1)
    }

    @Test func retargetMidRampStartsFromCurrentValue() {
        let g = GainSmoother(sampleRate: 48_000, rampSeconds: 0.015, initial: 0)
        g.setTarget(1)
        var last: Float = 0
        for _ in 0..<360 { last = g.next() }
        g.setTarget(0)
        let first = g.next()
        #expect(first < last && first > last - 0.01)       // no jump
        for _ in 0..<719 { last = g.next() }
        #expect(last == 0)
    }

    /// A 48 kHz mixer with the master already raised, and the stem data: `values[s]` constant on stem s.
    private func settledMixer(_ stems: [Stem], mix: StemMix) -> StemMixer {
        let mixer = StemMixer(stems: stems, sampleRate: 48_000)
        mixer.apply(mix)
        mixer.setMaster(1)
        _ = render(mixer, stems: stems.count, values: Array(repeating: 0, count: stems.count), frames: 4800)
        return mixer
    }

    private func render(_ mixer: StemMixer, stems: Int, values: [Float], frames: Int,
                        channels: Int = 2, outChannels: Int = 2, prefill: Float = 0) -> [Float] {
        var input = [Float](repeating: 0, count: stems * frames * channels)
        for s in 0..<stems {
            for i in 0..<(frames * channels) { input[s * frames * channels + i] = values[s] }
        }
        var out = [Float](repeating: prefill, count: frames * outChannels)
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                mixer.render(stemFrames: src.baseAddress!, frames: frames, channels: channels,
                             out: dst.baseAddress!, outChannels: outChannels)
            }
        }
        return out
    }

    @Test func presetChangeAudibleUnder50ms() {
        let mixer = settledMixer(Stem.live, mix: StemMix.allOn(Stem.live))
        // Only the voice has signal.
        let voiceOnly: [Float] = [1, 0, 0, 0]
        let before = render(mixer, stems: 4, values: voiceOnly, frames: 480)
        #expect(abs(before[0] - 1) < 1e-6)

        mixer.apply(StemMix.allOn(Stem.live).applying(.noVoice))
        let after = render(mixer, stems: 4, values: voiceOnly, frames: 2400)
        #expect(after[0] > 0.9)                                  // the change is smoothed, not a step
        #expect(after[2398] == 0 && after[2399] == 0)            // within 50 ms the voice is gone
    }

    @Test func mixSumsStemsWithVolumes() {
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.drums]?.volume = 0.5
        mix.controls[.bass]?.enabled = false
        let mixer = settledMixer(Stem.live, mix: mix)
        // Values by name: the order of Stem.live is the UI's and may change.
        let values: [Stem: Float] = [.vocals: 0.1, .drums: 0.2, .bass: 0.4, .other: 0.3]
        let out = render(mixer, stems: 4, values: Stem.live.map { values[$0]! }, frames: 64)
        #expect(abs(out[63 * 2] - (0.1 + 0.5 * 0.2 + 0.3)) < 1e-6)
    }

    @Test func masterStartsSilent() {
        let mixer = StemMixer(stems: Stem.live, sampleRate: 48_000)
        mixer.apply(StemMix.allOn(Stem.live))
        let silent = render(mixer, stems: 4, values: [1, 1, 1, 1], frames: 1000)
        #expect(silent.allSatisfy { $0 == 0 })

        mixer.setMaster(1)
        let fadeIn = render(mixer, stems: 4, values: [1, 1, 1, 1], frames: 1920)
        let left = stride(from: 0, to: fadeIn.count, by: 2).map { fadeIn[$0] }
        #expect(left[0] < 0.01)                                  // no thump: the first frame is almost zero
        #expect(zip(left, left.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(abs(left[1919] - 4) < 1e-5)                      // 40 ms later it is at steady state
    }

    @Test func multichannelOutputZeroesExtraChannels() {
        let mixer = settledMixer(Stem.live, mix: StemMix.allOn(Stem.live))
        let out = render(mixer, stems: 4, values: [0.25, 0, 0, 0], frames: 128, outChannels: 6, prefill: 9)
        for f in 0..<128 {
            #expect(abs(out[f * 6] - 0.25) < 1e-6 && abs(out[f * 6 + 1] - 0.25) < 1e-6)
            for c in 2..<6 { #expect(out[f * 6 + c] == 0) }
        }
    }

    @Test func stemChannelsStayOnTheirOutputChannels() {
        let mixer = settledMixer([.other], mix: StemMix.allOn([.other]))
        // Left channel 0.5 and right -0.5.
        let frames = 16
        var input = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { input[f * 2] = 0.5; input[f * 2 + 1] = -0.5 }
        var out = [Float](repeating: 0, count: frames * 2)
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                mixer.render(stemFrames: src.baseAddress!, frames: frames, channels: 2, out: dst.baseAddress!, outChannels: 2)
            }
        }
        #expect(out[0] == 0.5 && out[1] == -0.5)
    }

    /// An IOProc block with the timeline that has `ahead` frames ready from the playback point:
    /// frames beyond are 0, as `StemTimeline.read` gives them. Returns the left channel.
    private func gapBlock(_ mixer: StemMixer, ahead: Int64, frames: Int) -> [Float] {
        mixer.guardAgainstGap(framesAhead: ahead, frames: frames)
        let have = max(0, min(Int(ahead), frames))
        var input = [Float](repeating: 0, count: 4 * frames * 2)
        for s in 0..<4 { for f in 0..<have { input[(s * frames + f) * 2] = 1; input[(s * frames + f) * 2 + 1] = 1 } }
        var out = [Float](repeating: 0, count: frames * 2)
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                mixer.render(stemFrames: src.baseAddress!, frames: frames, channels: 2, out: dst.baseAddress!, outChannels: 2)
            }
        }
        return stride(from: 0, to: out.count, by: 2).map { out[$0] }
    }

    /// The model falls behind: the timeline ends. The sound must fall to zero before the gap,
    /// not cut off abruptly (the underrun click).
    @Test func fadesOutBeforeTheTimelineRunsOut() {
        let mixer = settledMixer(Stem.live, mix: StemMix.allOn(Stem.live))
        var left: [Float] = []
        var ahead: Int64 = 3000
        for _ in 0..<20 {
            left += gapBlock(mixer, ahead: ahead, frames: 256)
            ahead -= 256
        }
        #expect(left[0] == 4)
        let biggestStep = zip(left, left.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(biggestStep < 0.05)                    // 4 in 10 ms is ~0.008 per frame
        #expect(left.last == 0)
    }

    /// The stems come back: re-enter with a ramp, not a step.
    @Test func fadesBackInWhenStemsReturn() {
        let mixer = settledMixer(Stem.live, mix: StemMix.allOn(Stem.live))
        _ = gapBlock(mixer, ahead: 0, frames: 4800)    // buco: 100 ms a zero
        let back = (0..<4).flatMap { _ in gapBlock(mixer, ahead: 48_000, frames: 256) }
        #expect(back[0] < 0.05)
        #expect(zip(back, back.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(back.last == 4)
    }
}
