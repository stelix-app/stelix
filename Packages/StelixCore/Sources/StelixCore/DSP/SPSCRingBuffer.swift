// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Synchronization

/// Ring buffer of interleaved frames, one producer and one consumer, lock-free.
///
/// The producer (the IOProc) always writes and never waits: if the consumer lags behind, the
/// oldest frames are overwritten. Each frame has an absolute index (`0..<writtenFrames`) and the
/// consumer asks for a range by index; `copy` says whether the range was whole and valid.
///
/// Protocol (a seqlock with two indices):
/// - `reserved` = index up to which the producer *is* writing; published before the data,
///   followed by a release barrier, so whoever sees new data also sees the new `reserved`.
/// - `written` = index up to which the data is complete; published after the data with `.releasing`.
/// - `copy` reads `written` (acquire), copies, then an acquire barrier and reads `reserved` again: if in the
///   meantime the producer has reached the range, the copy is discarded.
public final class SPSCRingBuffer: @unchecked Sendable {
    public let channels: Int
    public let capacityFrames: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int64>(0)
    private let reserved = Atomic<Int64>(0)

    public init(channels: Int, capacityFrames: Int) {
        precondition(channels > 0 && capacityFrames > 0)
        var capacity = 1
        while capacity < capacityFrames { capacity <<= 1 }
        self.channels = channels
        self.capacityFrames = capacity
        self.mask = capacity - 1
        self.storage = .allocate(capacity: capacity * channels)
        storage.initialize(repeating: 0, count: capacity * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// Total frames written since the start.
    public var writtenFrames: Int64 { written.load(ordering: .acquiring) }

    /// Producer only. It does not allocate or block. If `frames` exceeds the capacity, the last ones remain.
    public func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let start = written.load(ordering: .relaxed)   // only the producer modifies it
        let end = start + Int64(frames)
        reserved.store(end, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)

        let skip = max(0, frames - capacityFrames)
        var frame = start + Int64(skip)
        var srcOffset = skip * channels
        var remaining = frames - skip
        while remaining > 0 {
            let slot = Int(frame) & mask
            let run = min(remaining, capacityFrames - slot)
            (storage + slot * channels).update(from: src + srcOffset, count: run * channels)
            frame += Int64(run)
            srcOffset += run * channels
            remaining -= run
        }
        written.store(end, ordering: .releasing)
    }

    /// Consumer only. `false` if part of the range has already been overwritten (even
    /// during the copy) or has not been written yet; in that case `dst` must be ignored.
    public func copy(from startFrame: Int64, frames: Int, into dst: UnsafeMutablePointer<Float>) -> Bool {
        guard startFrame >= 0, frames >= 0, frames <= capacityFrames else { return false }
        let end = startFrame + Int64(frames)
        guard end <= written.load(ordering: .acquiring) else { return false }
        guard startFrame >= reserved.load(ordering: .relaxed) - Int64(capacityFrames) else { return false }

        var frame = startFrame
        var dstOffset = 0
        var remaining = frames
        while remaining > 0 {
            let slot = Int(frame) & mask
            let run = min(remaining, capacityFrames - slot)
            (dst + dstOffset).update(from: storage + slot * channels, count: run * channels)
            frame += Int64(run)
            dstOffset += run * channels
            remaining -= run
        }

        atomicMemoryFence(ordering: .acquiring)
        return startFrame >= reserved.load(ordering: .relaxed) - Int64(capacityFrames)
    }
}
