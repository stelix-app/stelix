// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Silence in, silence out. Demucs normalizes each 7.8 s window by its loudness and leaves a residue
/// where the input is digital silence: after a song stops, a hiss at -70…-97 dBFS that fades for
/// about 7 s, as the music leaves the window (`spikes/DemucsBench tail`). Here the stems are zeroed
/// where the input is silent.
///
/// The input is looked at in blocks of `blockSeconds`, on absolute frame indices: the same frame
/// always gets the same gain, also in the provisional band that the next step rewrites. A block is
/// closed only if it and both its neighbors are silent, so the 1-block ramps fall inside the silence
/// and the attack and the tail of the music stay whole. Without input for a block (not written
/// yet, or overwritten) the block counts as music. Runs on the ML thread, never in the IOProc.
public enum SilenceGate {
    /// -100 dBFS: far below any music, above the digital silence of a paused player.
    public static let threshold: Float = 0.00001
    public static let blockSeconds = 0.01

    /// The input frames `apply` looks at for a chunk: the blocks from two before its first (the ramp of the
    /// first block) to the one after its last, whole. With less, the last block counts as music.
    public static func inputRange(startFrame: Int64, frames: Int, blockFrames: Int) -> Range<Int64> {
        let block = Int64(max(1, blockFrames))
        let firstBlock = floorDiv(startFrame, block)
        let lastBlock = floorDiv(startFrame + Int64(max(1, frames)) - 1, block)
        return (firstBlock - 2) * block ..< (lastBlock + 2) * block
    }

    /// `data`: [stem][frame][2] for the frames `startFrame ..< startFrame + frames`.
    /// `input`: `channels` interleaved, for the frames from `inputStart`.
    public static func apply(to data: inout [Float], stems: Int, startFrame: Int64, frames: Int,
                             input: [Float], inputStart: Int64, channels: Int, blockFrames: Int) {
        guard frames > 0, blockFrames > 0, channels > 0, data.count >= stems * frames * 2 else { return }
        let block = Int64(blockFrames)
        let inputFrames = Int64(input.count / channels)
        let firstBlock = floorDiv(startFrame, block)
        let lastBlock = floorDiv(startFrame + Int64(frames) - 1, block)

        // silent[k - firstBlock + 2] for the blocks firstBlock - 2 ... lastBlock + 1.
        let silent: [Bool] = (firstBlock - 2...lastBlock + 1).map { k in
            let from = k * block - inputStart
            let to = from + block
            guard from >= 0, to <= inputFrames else { return false }
            for frame in Int(from)..<Int(to) {
                for channel in 0..<channels where abs(input[frame * channels + channel]) >= threshold {
                    return false
                }
            }
            return true
        }
        guard silent.contains(true) else { return }
        func gain(_ k: Int64) -> Float {
            let index = Int(k - firstBlock) + 2
            return silent[index - 1] && silent[index] && silent[index + 1] ? 0 : 1
        }

        for k in firstBlock...lastBlock {
            let before = gain(k - 1)
            let after = gain(k)
            if before == 1 && after == 1 { continue }
            let blockStart = k * block
            let from = max(blockStart, startFrame)
            let to = min(blockStart + block, startFrame + Int64(frames))
            for absolute in from..<to {
                let step = Float(absolute - blockStart + 1) / Float(block)
                let value = before + (after - before) * step
                let frame = Int(absolute - startFrame)
                for stem in 0..<stems {
                    let base = (stem * frames + frame) * 2
                    data[base] *= value
                    data[base + 1] *= value
                }
            }
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}
