// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct StemTimelineTests {
    @Test func modelBudgetIsTheTighterOfHopAndMarginPlusLookahead() {
        for level in LiveLevel.allCases {
            #expect(level.modelBudget == min(level.hop, level.margin + level.lookahead))
            #expect(level.modelBudget <= level.hop)
        }
        #expect(LiveLevel.base.modelBudget == 0.30)
        #expect(LiveLevel.pro.modelBudget == 1.05)
    }

    // MARK: LiveTiming

    @Test func timingFollowsDeviceRate() {
        let at48 = LiveTiming(level: .intermediate, deviceRate: 48_000)
        #expect(at48.delayFrames == Int((LiveLevel.intermediate.targetDelay * 48_000).rounded()))
        #expect(at48.hopFrames == 24_000)
        #expect(at48.lookaheadFrames == 12_000)
        #expect(at48.crossfadeFrames == 720)
        #expect(abs(at48.delaySeconds - LiveLevel.intermediate.targetDelay) < 1e-9)

        let at24 = LiveTiming(level: .intermediate, deviceRate: 24_000)
        #expect(abs(at24.delayFrames * 2 - at48.delayFrames) <= 1)
        #expect(abs(at24.delaySeconds - at48.delaySeconds) < 1e-4)     // same delay in seconds
        #expect(at24 != at48)
    }

    @Test func timingCoversEveryLevel() {
        for level in LiveLevel.allCases {
            let t = LiveTiming(level: level, deviceRate: 44_100)
            #expect(t.delayFrames == Int((level.targetDelay * 44_100).rounded()))
            #expect(t.lookaheadFrames >= Int(0.1 * 44_100))
        }
    }

    // MARK: StemTimeline

    /// Recognizable sample value (stem s, frame f, channel c).
    private func value(_ s: Int, _ f: Int, _ c: Int) -> Float { Float(s * 100_000 + f) + (c == 0 ? 0 : 0.5) }

    private func block(stems: Int, channels: Int, from start: Int, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: stems * frames * channels)
        for s in 0..<stems {
            for f in 0..<frames {
                for c in 0..<channels { out[(s * frames + f) * channels + c] = value(s, start + f, c) }
            }
        }
        return out
    }

    private func write(_ t: StemTimeline, from start: Int, frames: Int, stems: Int = 4, channels: Int = 2) {
        let data = block(stems: stems, channels: channels, from: start, frames: frames)
        data.withUnsafeBufferPointer { t.write(startFrame: Int64(start), frames: frames, data: $0.baseAddress!) }
    }

    private func read(_ t: StemTimeline, at frame: Int, frames: Int, stems: Int = 4, channels: Int = 2) -> (Int, [Float]) {
        var dst = [Float](repeating: .nan, count: stems * frames * channels)
        let n = dst.withUnsafeMutableBufferPointer { t.read(at: Int64(frame), frames: frames, into: $0.baseAddress!) }
        return (n, dst)
    }

    /// A skipped band (ML thread late or failed pass) must not make readable the
    /// slots that still contain audio from one lap earlier than the capacity: it is an underrun, not old audio.
    @Test func writeAfterGapDoesNotExposeStaleFrames() {
        let t = StemTimeline(stems: 4, channels: 2, capacityFrames: 4096)
        write(t, from: 0, frames: 4096)          // fills every slot
        write(t, from: 4096, frames: 1000)
        write(t, from: 6000, frames: 1000)       // [5096, 6000) was never written
        let (gap, gapData) = read(t, at: 5500, frames: 100)
        #expect(gap == 0)
        #expect(gapData.allSatisfy { $0 == 0 })
        let (after, data) = read(t, at: 6000, frames: 100)
        #expect(after == 100)
        #expect(data[0] == value(0, 6000, 0))
    }

    @Test func modelStallIsMeasuredInFramesBehindTheRing() {
        let t = LiveTiming(level: .intermediate, deviceRate: 48_000)
        let limit = Int64(t.delayFrames + 3 * 48_000)
        // Normal: the timeline is behind by lookahead + hop + model time.
        #expect(!t.modelIsStalled(written: 200_000, available: 200_000 - Int64(t.lookaheadFrames + t.hopFrames + 9_000), playing: true))
        // Callback late at start: no frames, no stall.
        #expect(!t.modelIsStalled(written: 0, available: 0, playing: false))
        // The model has not delivered for more than the delay plus 3 s.
        #expect(t.modelIsStalled(written: limit + 1, available: 0, playing: false))
        #expect(!t.modelIsStalled(written: limit, available: 0, playing: false))
        #expect(t.modelIsStalled(written: 10 * limit, available: 10 * limit - limit - 1, playing: true))
        // It delivers, but too late to start: after delay + 3 s of input without playing.
        #expect(t.modelIsStalled(written: limit + 1, available: limit - 30_000, playing: false))
        #expect(!t.modelIsStalled(written: limit + 1, available: limit - 30_000, playing: true))
    }

    @Test func readReturnsWrittenFramesAtIndex() {
        let t = StemTimeline(stems: 4, channels: 2, capacityFrames: 4096)
        // Blocks of one hop, until wrapping around the capacity edge several times.
        var written = 0
        while written < 10_000 {
            write(t, from: written, frames: 700)
            written += 700
        }
        #expect(t.availableUpTo == Int64(written))
        let (n, dst) = read(t, at: 9_000, frames: 512)
        #expect(n == 512)
        #expect(dst == block(stems: 4, channels: 2, from: 9_000, frames: 512))
    }

    @Test func readPastAvailableZeroFillsAndReportsShort() {
        let t = StemTimeline(stems: 4, channels: 2, capacityFrames: 4096)
        write(t, from: 0, frames: 1_000)
        let (n, dst) = read(t, at: 900, frames: 200)
        #expect(n == 100)
        for s in 0..<4 {
            let stem = Array(dst[(s * 200 * 2)..<((s + 1) * 200 * 2)])
            #expect(Array(stem.prefix(200)) == Array(block(stems: 1, channels: 2, from: 900, frames: 100).map { $0 + Float(s * 100_000) }))
            #expect(stem.suffix(200).allSatisfy { $0 == 0 })
        }
        let (future, zeros) = read(t, at: 2_000, frames: 64)
        #expect(future == 0)
        #expect(zeros.allSatisfy { $0 == 0 })
    }

    @Test func readOfOverwrittenFramesReportsNothing() {
        let t = StemTimeline(stems: 1, channels: 2, capacityFrames: 1024)
        write(t, from: 0, frames: 3_000, stems: 1)
        let (n, dst) = read(t, at: 100, frames: 64, stems: 1)
        #expect(n == 0)
        #expect(dst.allSatisfy { $0 == 0 })
    }

    @Test func readBeforeFirstWriteReportsNothing() {
        let t = StemTimeline(stems: 1, channels: 2, capacityFrames: 1024)
        write(t, from: 500, frames: 200, stems: 1)
        #expect(read(t, at: 400, frames: 64, stems: 1).0 == 0)
        #expect(read(t, at: 500, frames: 64, stems: 1).0 == 64)
    }

    @Test func timelineResetsOnRebuild() {
        let t = StemTimeline(stems: 4, channels: 2, capacityFrames: 4096)
        write(t, from: 0, frames: 2_000)
        t.reset()
        #expect(t.availableUpTo == 0)
        let (n, dst) = read(t, at: 0, frames: 256)
        #expect(n == 0)
        #expect(dst.allSatisfy { $0 == 0 })
        // After the reset it starts again from 0 with the new tap.
        write(t, from: 0, frames: 256)
        #expect(read(t, at: 0, frames: 256).0 == 256)
    }
}
