// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// Where the Live input is digital silence the stems are silence too: the model leaves a residue there
/// (-70…-97 dBFS for ~7 s after a stop, measured with `spikes/DemucsBench tail`).
struct SilenceGateTests {
    private static let block = 4
    private static let loud: Float = 0.5
    private static let quiet: Float = 0

    /// 2 stems, every sample 0.01 (the residue), `frames` frames.
    private static func stems(_ frames: Int) -> [Float] {
        [Float](repeating: 0.01, count: 2 * frames * 2)
    }

    /// The gain applied to each frame of stem 0, left channel.
    private static func gains(_ data: [Float], frames: Int) -> [Float] {
        (0..<frames).map { data[$0 * 2] / 0.01 }
    }

    private static func run(input: [Float], inputStart: Int64 = 0, start: Int64, frames: Int) -> [Float] {
        var data = stems(frames)
        SilenceGate.apply(to: &data, stems: 2, startFrame: start, frames: frames,
                          input: input, inputStart: inputStart, channels: 1, blockFrames: block)
        return gains(data, frames: frames)
    }

    private static func signal(_ pieces: [(Int, Float)]) -> [Float] {
        pieces.flatMap { Array(repeating: $0.1, count: $0.0) }
    }

    @Test func musicIsUntouched() {
        let input = Self.signal([(40, Self.loud)])
        #expect(Self.run(input: input, start: 8, frames: 24).allSatisfy { $0 == 1 })
    }

    @Test func silenceGivesSilence() {
        let input = Self.signal([(40, Self.quiet)])
        #expect(Self.run(input: input, start: 8, frames: 24).allSatisfy { $0 == 0 })
    }

    /// After the music: one block stays open, the next fades out, then zero. The ramp is in the silence.
    @Test func afterTheMusicFadesInTheSilence() {
        let input = Self.signal([(16, Self.loud), (24, Self.quiet)])
        let gains = Self.run(input: input, start: 0, frames: 36)
        #expect(gains[0..<20].allSatisfy { $0 == 1 })          // music, and the block after it
        #expect(gains[20..<24] == [0.75, 0.5, 0.25, 0])         // the ramp, in block 5
        #expect(gains[24...].allSatisfy { $0 == 0 })
    }

    /// Before the music: the gain opens in the silent block before it, so the attack is whole.
    @Test func beforeTheMusicOpensInTheSilence() {
        let input = Self.signal([(28, Self.quiet), (20, Self.loud)])
        let gains = Self.run(input: input, start: 8, frames: 36)   // frames 8..<44
        #expect(gains[0..<16].allSatisfy { $0 == 0 })
        #expect(gains[16..<20] == [0.25, 0.5, 0.75, 1])         // block 6, silent
        #expect(gains[20...].allSatisfy { $0 == 1 })
    }

    /// Quiet music is music: -80 dBFS is not gated.
    @Test func quietMusicIsMusic() {
        let input = Self.signal([(40, 0.0001)])
        #expect(Self.run(input: input, start: 8, frames: 24).allSatisfy { $0 == 1 })
    }

    /// The blocks are on absolute frame indices: a chunk that starts elsewhere (the provisional band
    /// rewritten by the next step) gets the same gains for the same frames.
    @Test func sameFramesSameGains() {
        let input = Self.signal([(16, Self.loud), (24, Self.quiet)])
        let whole = Self.run(input: input, start: 0, frames: 36)
        let later = Self.run(input: input, start: 13, frames: 23)
        #expect(Array(whole[13...]) == later)
    }

    /// Input not available around the chunk (not written yet, or the ring moved on): left open.
    @Test func unknownInputStaysOpen() {
        let input = Self.signal([(4, Self.quiet)])
        // Input covers frames 104..<108 only (one silent block); the chunk is 100..<116.
        let gains = Self.run(input: input, inputStart: 104, start: 100, frames: 16)
        #expect(gains.allSatisfy { $0 == 1 })
    }

    /// The input to read for a chunk: from the block two before its first, to the end of the block
    /// after its last, which decides whether the last one closes.
    @Test func inputRangeCoversTheNeighborBlocks() {
        #expect(SilenceGate.inputRange(startFrame: 10, frames: 13, blockFrames: Self.block) == 0..<28)
        #expect(SilenceGate.inputRange(startFrame: 8, frames: 16, blockFrames: Self.block) == 0..<28)
        #expect(SilenceGate.inputRange(startFrame: 4, frames: 1, blockFrames: Self.block) == -4..<12)
    }

    /// Fed the input of `inputRange`, a chunk in the silence closes up to its last frame, wherever it ends.
    @Test func theLastBlockClosesWithTheInputOfInputRange() {
        for (start, frames) in [(Int64(40), 13), (41, 14), (40, 16), (43, 1)] {
            let range = SilenceGate.inputRange(startFrame: start, frames: frames, blockFrames: Self.block)
            let input = [Float](repeating: Self.quiet, count: Int(range.count))
            let gains = Self.run(input: input, inputStart: range.lowerBound, start: start, frames: frames)
            #expect(gains.allSatisfy { $0 == 0 }, "\(start), \(frames)")
        }
    }

    /// Several input channels: one with signal keeps the block open.
    @Test func anyChannelCounts() {
        var data = Self.stems(8)
        var input = [Float](repeating: 0, count: 32 * 2)
        for frame in 0..<32 { input[frame * 2 + 1] = Self.loud }
        SilenceGate.apply(to: &data, stems: 2, startFrame: 8, frames: 8, input: input, inputStart: 0,
                          channels: 2, blockFrames: Self.block)
        #expect(Self.gains(data, frames: 8).allSatisfy { $0 == 1 })
    }

    /// The gain is applied to every stem and both channels.
    @Test func everyStemAndChannel() {
        var data = Self.stems(12)
        SilenceGate.apply(to: &data, stems: 2, startFrame: 8, frames: 12, input: [Float](repeating: 0, count: 40),
                          inputStart: 0, channels: 1, blockFrames: Self.block)
        #expect(data.allSatisfy { $0 == 0 })
    }
}
