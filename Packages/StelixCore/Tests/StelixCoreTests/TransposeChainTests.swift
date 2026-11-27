// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct TransposeChainTests {
    /// The chain over `drums` and `rest`, in blocks of 512 frames.
    private static func run(_ chain: TransposeChain, drums: [Float], rest: [Float]) -> [Float] {
        let frames = drums.count / 2
        var out = [Float](repeating: 0, count: frames * 2)
        drums.withUnsafeBufferPointer { d in
            rest.withUnsafeBufferPointer { r in
                out.withUnsafeMutableBufferPointer { o in
                    var done = 0
                    while done < frames {
                        let n = min(512, frames - done)
                        chain.process(drums: d.baseAddress! + done * 2, rest: r.baseAddress! + done * 2, frames: n,
                                      into: o.baseAddress! + done * 2)
                        done += n
                    }
                }
            }
        }
        return out
    }

    @Test func silentForTheLatencyThenRampsIn() {
        let rate = 48_000.0
        let chain = TransposeChain(shifter: FakeShifter(latency: 300), sampleRate: rate, semitones: 3)
        let frames = 6000
        let rest = [Float](repeating: 0.5, count: frames * 2)
        let out = Self.run(chain, drums: [Float](repeating: 0, count: frames * 2), rest: rest)
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        #expect(left[0..<300].allSatisfy { $0 == 0 })
        #expect(left[310] > 0 && left[310] < 0.1)                       // the 40 ms ramp has just started
        #expect(zip(left, left.dropFirst()).allSatisfy { $0 <= $1 + 1e-7 })
        #expect(abs(left[300 + 1920 + 10] - 0.5) < 1e-6)                // ramp over: full level
    }

    @Test func drumsAndRestStayAligned() {
        let rate = 48_000.0, frames = 10_000
        let click = AudioTestSignals.click(frames: frames, at: 5000, rate: rate)
        let silence = [Float](repeating: 0, count: frames * 2)
        let drumsOnly = Self.run(TransposeChain(shifter: FakeShifter(latency: 300), sampleRate: rate, semitones: 3),
                                 drums: click, rest: silence)
        let restOnly = Self.run(TransposeChain(shifter: FakeShifter(latency: 300), sampleRate: rate, semitones: 3),
                                drums: silence, rest: click)
        #expect(AudioTestSignals.onset(drumsOnly, rate: rate) == AudioTestSignals.onset(restOnly, rate: rate))
        #expect(AudioTestSignals.onset(drumsOnly, rate: rate) == AudioTestSignals.onset(click, rate: rate).map { $0 + 300 })
    }

    private static func appleAlignment(rate: Double, semitones: Int) throws -> Int {
        let frames = Int(rate * 2)
        let click = AudioTestSignals.click(frames: frames, at: Int(rate), rate: rate)
        let silence = [Float](repeating: 0, count: frames * 2)
        let drumsOnly = Self.run(try TransposeChain(sampleRate: rate, semitones: semitones), drums: click, rest: silence)
        let restOnly = Self.run(try TransposeChain(sampleRate: rate, semitones: semitones), drums: silence, rest: click)
        let d = try #require(AudioTestSignals.onset(drumsOnly, rate: rate))
        let r = try #require(AudioTestSignals.onset(restOnly, rate: rate))
        return abs(d - r)
    }

    @Test(arguments: [3, -5])
    func appleKeepsDrumsAlignedWithin1ms(semitones: Int) throws {
        #expect(try Self.appleAlignment(rate: 48_000, semitones: semitones) <= 48)
    }

    @Test func appleKeepsDrumsAlignedAt24k() throws {
        #expect(try Self.appleAlignment(rate: 24_000, semitones: 3) <= 24)
    }

    @Test func retuneReachesTheShifter() {
        let fake = FakeShifter(latency: 300)
        let chain = TransposeChain(shifter: fake, sampleRate: 48_000, semitones: 3)
        chain.setSemitones(5)
        chain.setSemitones(5)
        #expect(fake.calls == [3, 5])
    }
}

struct TransposeTransitionTests {
    @Test func fromZeroEnters() { #expect(TransposeTransition(from: .off, to: Transpose(semitones: 3)) == .enter(3)) }
    @Test func toZeroLeaves() { #expect(TransposeTransition(from: Transpose(semitones: 3), to: .off) == .leave) }
    @Test func betweenValuesRetunes() {
        #expect(TransposeTransition(from: Transpose(semitones: 3), to: Transpose(semitones: -2)) == .retune(-2))
    }
    @Test func sameValueDoesNothing() {
        #expect(TransposeTransition(from: Transpose(semitones: 3), to: Transpose(semitones: 3)) == TransposeTransition.none)
        #expect(TransposeTransition(from: .off, to: .off) == TransposeTransition.none)
    }
    @Test func quickClicksEndOnTheLastValue() {
        var current = Transpose.off
        var steps: [TransposeTransition] = []
        for value in [1, 0, -1] {
            let next = Transpose(semitones: value)
            steps.append(TransposeTransition(from: current, to: next))
            current = next
        }
        #expect(steps == [.enter(1), .leave, .enter(-1)])
        #expect(current.semitones == -1)
    }
}
