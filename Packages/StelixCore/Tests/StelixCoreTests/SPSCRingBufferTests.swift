// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization
import Testing
@testable import StelixCore

struct SPSCRingBufferTests {
    /// Interleaved ramp: frame f is f on channel 0 and -f on channel 1.
    private func ramp(from start: Int, count: Int, channels: Int = 2) -> [Float] {
        var out = [Float](repeating: 0, count: count * channels)
        for i in 0..<count {
            for c in 0..<channels { out[i * channels + c] = c == 0 ? Float(start + i) : -Float(start + i) }
        }
        return out
    }

    private func write(_ ring: SPSCRingBuffer, _ samples: [Float], frames: Int) {
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
    }

    @Test func capacityRoundsUpToPowerOfTwo() {
        let ring = SPSCRingBuffer(channels: 2, capacityFrames: 1000)
        #expect(ring.capacityFrames == 1024)
    }

    @Test func wrapsAroundPreservingFrameIndex() {
        let ring = SPSCRingBuffer(channels: 2, capacityFrames: 1024)
        // Blocks of different sizes, so the write crosses the edge at several points.
        var written = 0
        for size in [100, 700, 513, 1024, 663] {
            write(ring, ramp(from: written, count: size), frames: size)
            written += size
        }
        #expect(written == 3000)
        #expect(ring.writtenFrames == 3000)

        var dst = [Float](repeating: .nan, count: 400 * 2)
        let ok = dst.withUnsafeMutableBufferPointer { ring.copy(from: 2500, frames: 400, into: $0.baseAddress!) }
        #expect(ok)
        #expect(dst == ramp(from: 2500, count: 400))
    }

    @Test func rejectsOverwrittenRange() {
        let ring = SPSCRingBuffer(channels: 2, capacityFrames: 1024)
        write(ring, ramp(from: 0, count: 3000), frames: 3000)
        var dst = [Float](repeating: 0, count: 400 * 2)
        let ok = dst.withUnsafeMutableBufferPointer { ring.copy(from: 0, frames: 400, into: $0.baseAddress!) }
        #expect(!ok)
        // The first frame still present is 3000 - 1024 = 1976; 1975 is already lost.
        let edge = dst.withUnsafeMutableBufferPointer { ring.copy(from: 1975, frames: 10, into: $0.baseAddress!) }
        #expect(!edge)
        let oldest = dst.withUnsafeMutableBufferPointer { ring.copy(from: 1976, frames: 10, into: $0.baseAddress!) }
        #expect(oldest)
        #expect(Array(dst.prefix(20)) == ramp(from: 1976, count: 10))
    }

    @Test func rejectsFutureRange() {
        let ring = SPSCRingBuffer(channels: 2, capacityFrames: 1024)
        write(ring, ramp(from: 0, count: 500), frames: 500)
        var dst = [Float](repeating: 0, count: 100 * 2)
        let future = dst.withUnsafeMutableBufferPointer { ring.copy(from: 450, frames: 100, into: $0.baseAddress!) }
        #expect(!future)
        let exact = dst.withUnsafeMutableBufferPointer { ring.copy(from: 400, frames: 100, into: $0.baseAddress!) }
        #expect(exact)
        let negative = dst.withUnsafeMutableBufferPointer { ring.copy(from: -1, frames: 10, into: $0.baseAddress!) }
        #expect(!negative)
    }

    @Test func rejectsRangeLongerThanCapacity() {
        let ring = SPSCRingBuffer(channels: 1, capacityFrames: 64)
        let samples = (0..<200).map(Float.init)
        write(ring, samples, frames: 200)
        var dst = [Float](repeating: 0, count: 100)
        let ok = dst.withUnsafeMutableBufferPointer { ring.copy(from: 100, frames: 100, into: $0.baseAddress!) }
        #expect(!ok)
    }

    @Test func concurrentProducerConsumerStress() async {
        // The value is frame % modulus, to stay exact in Float even after millions of frames.
        let modulo = 1 << 20
        let channels = 2
        // Capacity equal to the copied window: every write during the copy overwrites its start.
        let ring = SPSCRingBuffer(channels: channels, capacityFrames: 4096)
        let stop = Atomic<Bool>(false)
        let broken = Atomic<Int>(0)
        let succeeded = Atomic<Int>(0)

        let producer = Thread {
            var block = [Float](repeating: 0, count: 512 * channels)
            var frame = 0
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                for i in 0..<512 {
                    let v = Float((frame + i) % modulo)
                    block[i * channels] = v
                    block[i * channels + 1] = -v
                }
                block.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 512) }
                frame += 512
            }
            stop.store(true, ordering: .releasing)
        }
        let consumer = Thread {
            var dst = [Float](repeating: 0, count: 4096 * channels)
            while !stop.load(ordering: .acquiring) {
                let w = ring.writtenFrames
                guard w >= 4096 else { continue }
                let start = w - 4096
                let ok = dst.withUnsafeMutableBufferPointer { ring.copy(from: start, frames: 4096, into: $0.baseAddress!) }
                guard ok else { continue }
                succeeded.add(1, ordering: .relaxed)
                for i in 0..<4096 {
                    let expected = Float((Int(start) + i) % modulo)
                    if dst[i * channels] != expected || dst[i * channels + 1] != -expected {
                        broken.add(1, ordering: .relaxed)
                        break
                    }
                }
            }
        }
        producer.start()
        consumer.start()
        while !stop.load(ordering: .acquiring) { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(broken.load(ordering: .relaxed) == 0)
        #expect(succeeded.load(ordering: .relaxed) > 100)
    }
}
