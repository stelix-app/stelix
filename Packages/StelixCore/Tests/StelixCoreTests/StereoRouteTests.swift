// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CoreAudio
import Testing
@testable import StelixCore

/// Fake Core Audio buffers: each buffer has its own interleaved channels, or `mData` nil.
private final class FakeBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(_ buffers: [(channels: Int, frames: Int, fill: Float?)]) {
        list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        for (i, b) in buffers.enumerated() {
            var data: UnsafeMutableRawPointer?
            if let fill = b.fill {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: b.channels * b.frames)
                // Each sample is fill + channel: you can tell where it comes from.
                for f in 0..<b.frames { for c in 0..<b.channels { p[f * b.channels + c] = fill + Float(c) } }
                storage.append(p)
                data = UnsafeMutableRawPointer(p)
            }
            list[i] = AudioBuffer(mNumberChannels: UInt32(b.channels),
                                  mDataByteSize: UInt32(b.channels * b.frames * MemoryLayout<Float>.size), mData: data)
        }
    }

    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        let n = Int(list[buffer].mNumberChannels)
        return list[buffer].mData!.assumingMemoryBound(to: Float.self)[frame * n + channel]
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

struct StereoRouteTests {
    // MARK: - Pair choice

    @Test func defaultsToFirstPairWithoutPreference() throws {
        let route = try #require(StereoRoute(streamChannels: [2], preferredStereo: nil))
        #expect(route == StereoRoute(stream: 0, tapLeft: 0, tapRight: 1, outLeft: 0, outRight: 1))
    }

    /// The UMC with the macOS stereo on channels 3-4: a single 4-channel stream.
    @Test func followsPreferredPairInsideOneStream() throws {
        let route = try #require(StereoRoute(streamChannels: [4], preferredStereo: (3, 4)))
        #expect(route == StereoRoute(stream: 0, tapLeft: 2, tapRight: 3, outLeft: 2, outRight: 3))
    }

    @Test func picksTheStreamThatHoldsThePair() throws {
        let route = try #require(StereoRoute(streamChannels: [2, 2], preferredStereo: (3, 4)))
        #expect(route == StereoRoute(stream: 1, tapLeft: 0, tapRight: 1, outLeft: 2, outRight: 3))
    }

    @Test func monoDeviceUsesItsOnlyChannelTwice() throws {
        let route = try #require(StereoRoute(streamChannels: [1], preferredStereo: (1, 2)))
        #expect(route == StereoRoute(stream: 0, tapLeft: 0, tapRight: 0, outLeft: 0, outRight: 0))
    }

    @Test func pairOutOfRangeOrAcrossStreamsFallsBackToFirstPair() throws {
        let first = StereoRoute(stream: 0, tapLeft: 0, tapRight: 1, outLeft: 0, outRight: 1)
        #expect(StereoRoute(streamChannels: [4], preferredStereo: (5, 6)) == first)
        #expect(StereoRoute(streamChannels: [2, 2], preferredStereo: (2, 3)) == first)
        #expect(StereoRoute(streamChannels: [4], preferredStereo: (0, 1)) == first)
    }

    /// A device that has just disappeared can have 0 output channels: no route, the engine says noOutput.
    @Test func noOutputChannelsGivesNoRoute() {
        #expect(StereoRoute(streamChannels: [], preferredStereo: nil) == nil)
        #expect(StereoRoute(streamChannels: [0], preferredStereo: (1, 2)) == nil)
    }

    // MARK: - IOProc

    /// Device inputs turned off (mData nil) and then the 4-channel tap: the tap's channels 3-4 arrive.
    @Test func gatherTakesThePairFromTheTapAtTheEnd() {
        let input = FakeBuffers([(2, 8, nil), (4, 8, 10)])
        let route = StereoRoute(stream: 0, tapLeft: 2, tapRight: 3, outLeft: 2, outRight: 3)
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { dst.deallocate() }
        withExtendedLifetime(input) {
            route.gather(input.list, tapChannels: 4, offset: 0, frames: 8, into: dst)
        }
        #expect((0..<8).allSatisfy { dst[$0 * 2] == 12 && dst[$0 * 2 + 1] == 13 })
    }

    /// The tap stream without data must not leave the callback's earlier samples.
    @Test func gatherZeroesWhenTheTapHasNoData() {
        let route = StereoRoute(stream: 0, tapLeft: 0, tapRight: 1, outLeft: 0, outRight: 1)
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { dst.deallocate() }
        dst.initialize(repeating: 7, count: 16)
        let input = FakeBuffers([(2, 8, nil)])
        withExtendedLifetime(input) {
            route.gather(input.list, tapChannels: 2, offset: 0, frames: 8, into: dst)
        }
        #expect((0..<16).allSatisfy { dst[$0] == 0 })
    }

    @Test func scatterWritesThePairAndZeroesTheRest() {
        let output = FakeBuffers([(4, 4, 99)])
        let route = StereoRoute(stream: 0, tapLeft: 2, tapRight: 3, outLeft: 2, outRight: 3)
        let src: [Float] = [1, 2, 1, 2, 1, 2, 1, 2]
        route.scatter(src, offset: 0, frames: 4, into: output.list)
        for f in 0..<4 {
            #expect(output.sample(buffer: 0, frame: f, channel: 0) == 0)
            #expect(output.sample(buffer: 0, frame: f, channel: 1) == 0)
            #expect(output.sample(buffer: 0, frame: f, channel: 2) == 1)
            #expect(output.sample(buffer: 0, frame: f, channel: 3) == 2)
        }
    }

    @Test func scatterAcrossTwoStreams() {
        let output = FakeBuffers([(2, 4, 99), (2, 4, 99)])
        let route = StereoRoute(stream: 1, tapLeft: 0, tapRight: 1, outLeft: 2, outRight: 3)
        route.scatter([Float](repeating: 0.5, count: 8), offset: 0, frames: 4, into: output.list)
        #expect(output.sample(buffer: 0, frame: 3, channel: 1) == 0)
        #expect(output.sample(buffer: 1, frame: 3, channel: 0) == 0.5)
        #expect(output.sample(buffer: 1, frame: 3, channel: 1) == 0.5)
    }

    /// The callback's output has fewer channels than the route's: it plays on the first two instead
    /// of staying at zero for the whole session.
    @Test func scatterFallsBackToFirstPairWhenTheOutputShrinks() {
        let output = FakeBuffers([(2, 4, 99)])
        let route = StereoRoute(stream: 0, tapLeft: 2, tapRight: 3, outLeft: 2, outRight: 3)
        route.scatter([Float](repeating: 0.25, count: 8), offset: 0, frames: 4, into: output.list)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0.25)
        #expect(output.sample(buffer: 0, frame: 0, channel: 1) == 0.25)
    }

    @Test func scatterToMonoWritesTheAverage() {
        let output = FakeBuffers([(1, 2, 99)])
        let route = StereoRoute(stream: 0, tapLeft: 0, tapRight: 0, outLeft: 0, outRight: 0)
        route.scatter([1, 0, 1, 0], offset: 0, frames: 2, into: output.list)
        #expect(output.sample(buffer: 0, frame: 1, channel: 0) == 0.5)
    }

    /// `offset` shifts the write in the device buffers (blocks longer than maxFrames).
    @Test func scatterHonoursOffset() {
        let output = FakeBuffers([(2, 4, 99)])
        let route = StereoRoute(stream: 0, tapLeft: 0, tapRight: 1, outLeft: 0, outRight: 1)
        route.scatter([3, 4], offset: 2, frames: 1, into: output.list)
        #expect(output.sample(buffer: 0, frame: 2, channel: 0) == 3)
        #expect(output.sample(buffer: 0, frame: 2, channel: 1) == 4)
    }
}
