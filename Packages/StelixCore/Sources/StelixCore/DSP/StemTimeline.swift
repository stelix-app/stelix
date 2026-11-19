// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Synchronization

/// The stems already computed, indexed by input frame. One producer (the ML thread) and one
/// consumer (the IOProc).
///
/// Data is [stem][frame][channel] both when writing and when reading. The producer usually writes
/// forward and in contiguous blocks; a frame is readable if it is in `[oldest, availableUpTo)`.
/// The capacity must be well above the delay: the consumer reads about `delay` frames behind
/// the input, and the producer writes just behind the input, so they never meet on the
/// same slot as long as `capacity > delay + hop`.
public final class StemTimeline: @unchecked Sendable {
    public let stems: Int
    public let channels: Int
    public let capacityFrames: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let available = Atomic<Int64>(0)
    private let oldest = Atomic<Int64>(0)
    private var hasData = false   // producer only

    public init(stems: Int, channels: Int, capacityFrames: Int) {
        precondition(stems > 0 && channels > 0 && capacityFrames > 0)
        var capacity = 1
        while capacity < capacityFrames { capacity <<= 1 }
        self.stems = stems
        self.channels = channels
        self.capacityFrames = capacity
        mask = capacity - 1
        storage = .allocate(capacity: stems * capacity * channels)
        storage.initialize(repeating: 0, count: stems * capacity * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// First frame not yet written.
    public var availableUpTo: Int64 { available.load(ordering: .acquiring) }

    /// Producer only. `data` is [stem][frame][channel] with `frames` frames per stem.
    public func write(startFrame: Int64, frames: Int, data: UnsafePointer<Float>) {
        guard frames > 0, startFrame >= 0 else { return }
        let skip = max(0, frames - capacityFrames)
        let first = startFrame + Int64(skip)
        let end = startFrame + Int64(frames)
        let count = frames - skip
        for s in 0..<stems {
            let stemBase = storage + s * capacityFrames * channels
            let src = data + (s * frames + skip) * channels
            var frame = first
            var offset = 0
            while offset < count {
                let slot = Int(frame) & mask
                let run = min(count - offset, capacityFrames - slot)
                (stemBase + slot * channels).update(from: src + offset * channels, count: run * channels)
                frame += Int64(run)
                offset += run
            }
        }
        let previousEnd = available.load(ordering: .relaxed)
        let newEnd = max(previousEnd, end)
        // A gap between the previous end and this block (skipped band) was never written: its
        // slots still hold the audio from one lap ago. Only the frames from here on are read.
        let base: Int64
        if !hasData { base = first }
        else if first > previousEnd { base = first }
        else { base = min(oldest.load(ordering: .relaxed), first) }
        hasData = true
        oldest.store(max(base, newEnd - Int64(capacityFrames)), ordering: .relaxed)
        available.store(newEnd, ordering: .releasing)
    }

    /// Consumer only. Copies into `into` ([stem][frame][channel], `frames` per stem) the contiguous
    /// frames available from `frame` and fills the rest with zeros. Returns how many were available:
    /// fewer than `frames` is an underrun.
    public func read(at frame: Int64, frames: Int, into dst: UnsafeMutablePointer<Float>) -> Int {
        guard frames > 0 else { return 0 }
        let end = available.load(ordering: .acquiring)
        let start = oldest.load(ordering: .relaxed)
        let count = frame >= start && frame < end ? Int(min(Int64(frames), end - frame)) : 0
        for s in 0..<stems {
            let stemBase = storage + s * capacityFrames * channels
            let out = dst + s * frames * channels
            var f = frame
            var offset = 0
            while offset < count {
                let slot = Int(f) & mask
                let run = min(count - offset, capacityFrames - slot)
                (out + offset * channels).update(from: stemBase + slot * channels, count: run * channels)
                f += Int64(run)
                offset += run
            }
            if count < frames {
                (out + count * channels).update(repeating: 0, count: (frames - count) * channels)
            }
        }
        return count
    }

    /// Only with the IOProc and the ML thread stopped: restart from frame 0 with the new tap.
    public func reset() {
        hasData = false
        oldest.store(0, ordering: .relaxed)
        available.store(0, ordering: .releasing)
    }
}
