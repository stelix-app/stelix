// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CoreAudio

/// The stereo pair Stelix uses on an output: the one macOS uses for stereo
/// (Audio MIDI Setup → Configure Speakers, `kAudioDevicePropertyPreferredChannelsForStereo`),
/// usually 1-2 but for example 3-4 on a card with several outputs.
///
/// The tap goes on the device stream that contains the pair; the model receives those two channels
/// and the stems return on the same ones. While Live plays, the other output channels stay at zero
/// (the `.mutedWhenTapped` tap silences them anyway): a 5.1 is heard only on the stereo pair.
///
/// `gather` and `scatter` run in the IOProc: no allocations, no locks.
public struct StereoRoute: Equatable, Sendable {
    /// The device's output stream on which to put the tap.
    public let stream: Int
    /// The two channels of the pair inside that stream, that is, inside the tap.
    public let tapLeft: Int
    public let tapRight: Int
    /// The same channels counted over the whole device, that is, on the aggregate's output.
    public let outLeft: Int
    public let outRight: Int

    public init(stream: Int, tapLeft: Int, tapRight: Int, outLeft: Int, outRight: Int) {
        self.stream = stream
        self.tapLeft = tapLeft
        self.tapRight = tapRight
        self.outLeft = outLeft
        self.outRight = outRight
    }

    /// `streamChannels`: the channels of each output stream, in order. `preferredStereo`: the macOS
    /// pair, counted from 1. If the pair is missing or does not fit in a single stream, the first two
    /// channels are used, then the first alone (mono). With no output channels: nil.
    public init?(streamChannels: [Int], preferredStereo: (left: UInt32, right: UInt32)?) {
        let candidates: [(Int, Int)] = (preferredStereo.map { [(Int($0.left) - 1, Int($0.right) - 1)] } ?? [])
            + [(0, 1), (0, 0)]
        for (left, right) in candidates {
            if let route = Self.pair(left, right, in: streamChannels) {
                self = route
                return
            }
        }
        return nil
    }

    private static func pair(_ left: Int, _ right: Int, in streams: [Int]) -> StereoRoute? {
        let total = streams.reduce(0, +)
        guard left >= 0, right >= 0, left < total, right < total else { return nil }
        var start = 0
        for (index, channels) in streams.enumerated() {
            defer { start += channels }
            guard left >= start, left < start + channels else { continue }
            guard right >= start, right < start + channels else { return nil }
            return StereoRoute(stream: index, tapLeft: left - start, tapRight: right - start,
                               outLeft: left, outRight: right)
        }
        return nil
    }

    // MARK: - IOProc

    /// Writes into `dst` (interleaved stereo, `frames` frames) the pair taken from the tap, which occupies the
    /// last `tapChannels` channels of the aggregate's input. A missing channel, or a stream
    /// with `mData` nil, is 0.
    public func gather(_ list: UnsafeMutableAudioBufferListPointer, tapChannels: Int, offset: Int, frames: Int,
                       into dst: UnsafeMutablePointer<Float>) {
        dst.update(repeating: 0, count: frames * 2)
        var total = 0
        for buffer in list { total += Int(buffer.mNumberChannels) }
        let base = total - tapChannels
        guard base >= 0 else { return }
        Self.copy(list, channel: base + tapLeft, offset: offset, frames: frames, into: dst)
        Self.copy(list, channel: base + tapRight, offset: offset, frames: frames, into: dst + 1)
    }

    /// Writes `src` (interleaved stereo, `frames` frames) onto the output pair, from `offset` on,
    /// and zeroes the other channels. If the callback's output lacks the route's channels (it changed
    /// underneath) it plays on the first two; on a mono output the average goes.
    public func scatter(_ src: UnsafePointer<Float>, offset: Int, frames: Int,
                        into list: UnsafeMutableAudioBufferListPointer) {
        var total = 0
        for buffer in list {
            let n = Int(buffer.mNumberChannels)
            total += n
            guard n > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n)
            let end = min(offset + frames, available)
            if end > offset { (data + offset * n).update(repeating: 0, count: (end - offset) * n) }
        }
        guard total > 0 else { return }
        var left = outLeft, right = outRight
        if left >= total || right >= total { left = 0; right = min(1, total - 1) }

        var base = 0
        for buffer in list {
            let n = Int(buffer.mNumberChannels)
            defer { base += n }
            guard n > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n)
            let hasLeft = left >= base && left < base + n
            let hasRight = right >= base && right < base + n
            guard hasLeft || hasRight else { continue }
            for f in 0..<frames where offset + f < available {
                let frame = data + (offset + f) * n
                let l = src[f * 2], r = src[f * 2 + 1]
                if left == right {
                    frame[left - base] = (l + r) * 0.5
                } else {
                    if hasLeft { frame[left - base] = l }
                    if hasRight { frame[right - base] = r }
                }
            }
        }
    }

    /// Copies the logical channel `channel` of the input into `dst`, one sample every 2.
    @inline(__always)
    private static func copy(_ list: UnsafeMutableAudioBufferListPointer, channel: Int, offset: Int, frames: Int,
                             into dst: UnsafeMutablePointer<Float>) {
        var base = 0
        for buffer in list {
            let n = Int(buffer.mNumberChannels)
            defer { base += n }
            guard channel >= base, channel < base + n else { continue }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n)
            let c = channel - base
            for f in 0..<frames where offset + f < available { dst[f * 2] = data[(offset + f) * n + c] }
            return
        }
    }
}
