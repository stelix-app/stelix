// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import Testing
@testable import StelixCore

/// The Studio player's graph, rendered by hand (manual rendering) in real-time mode, as the player plays:
/// nothing comes out of the speakers. Offline the time pitch pulls its input ahead and hides its delay.
struct StudioGraphTests {
    static let rate = 44_100.0

    /// A folder with two stems, vocals and drums, 2 s each.
    private final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: "StudioGraphTests-\(UUID().uuidString)")
        let engine = AVAudioEngine()
        let graph: StudioGraph
        /// Frames per render call: 4096 offline, as small as the output's IO buffer in the real player.
        let slice: Int

        init(vocals: [Float], drums: [Float], slice: Int = 4096) throws {
            self.slice = slice
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [Stem: AVAudioFile] = [:]
            for (stem, interleaved) in [(Stem.vocals, vocals), (.drums, drums)] {
                let frames = interleaved.count / 2
                var planar = [Float](repeating: 0, count: frames * 2)
                for f in 0..<frames {
                    planar[f] = interleaved[f * 2]
                    planar[frames + f] = interleaved[f * 2 + 1]
                }
                let url = folder.appending(path: stem.fileName)
                try StemFiles.writeWAV(planar, frames: frames, sampleRate: StudioGraphTests.rate, to: url)
                files[stem] = try AVAudioFile(forReading: url)
            }
            try engine.enableManualRenderingMode(.realtime, format: AVAudioFormat(standardFormatWithSampleRate: StudioGraphTests.rate, channels: 2)!,
                                                 maximumFrameCount: AVAudioFrameCount(slice))
            graph = try StudioGraph(engine: engine, files: files)
        }

        deinit {
            engine.stop()
            try? FileManager.default.removeItem(at: folder)
        }

        /// `lead`: frames in the future at which the graph starts, as the real player does (50 ms).
        func start(from frame: AVAudioFramePosition = 0, lead: AVAudioFramePosition = 0) throws {
            if !engine.isRunning { try engine.start() }
            graph.schedule(from: frame)
            graph.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime + lead, atRate: StudioGraphTests.rate))
            // The players read their files on another thread: give them time to fill, as the real output does.
            Thread.sleep(forTimeInterval: 0.3)
        }

        /// `frames` of output, stereo interleaved.
        func render(_ frames: Int) throws -> [Float] {
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(slice))!
            var out: [Float] = []
            while out.count / 2 < frames {
                let n = AVAudioFrameCount(min(slice, frames - out.count / 2))
                var status = OSStatus(noErr)
                buffer.frameLength = n
                _ = engine.manualRenderingBlock(n, buffer.mutableAudioBufferList, &status)
                let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
                for f in 0..<Int(buffer.frameLength) { out.append(l[f]); out.append(r[f]) }
            }
            return out
        }

        func rewire(_ transpose: Transpose) throws {
            engine.stop()
            graph.setTranspose(transpose)
        }
    }

    private static func constant(_ value: Float) -> [Float] { [Float](repeating: value, count: Int(rate) * 2 * 2) }

    @Test func offGraphIsTheDirectSum() throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        #expect(fixture.graph.latencyFrames == 0)
        try fixture.start()
        let out = try fixture.render(8192)
        #expect(abs(out[8000 * 2] - 0.3) < 1e-6)
    }

    /// The limiter's lookahead, 2 ms, after the sum; the time pitch's own delay, about 93 ms, before it on
    /// the transposed stems only, and so on the drums too.
    @Test func transposedLatencies() throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        #expect(fixture.graph.drumsDelayFrames == 0)
        try fixture.rewire(Transpose(semitones: 3))
        try fixture.start()
        #expect(fixture.graph.latencyFrames > 0 && fixture.graph.latencyFrames < 441)
        #expect(fixture.graph.drumsDelayFrames > 3000 && fixture.graph.drumsDelayFrames < 5000)
    }

    /// The position comes from the drums, which start `drumsDelayFrames` late, as late as the transposed
    /// stems come out of the time pitch.
    @Test func clockNodeFollowsWhatIsHeard() throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        try fixture.rewire(Transpose(semitones: 3))
        try fixture.start()
        _ = try fixture.render(44_100)
        let node = fixture.graph.clockNode
        let time = try #require(node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0) })
        let expected = 44_100 - fixture.graph.drumsDelayFrames
        #expect(abs(Int(time.sampleTime) - expected) < 1024, "\(time.sampleTime), expected \(expected)")
    }

    /// At once and with the real player's start 50 ms ahead; in big slices and in slices as small as a real
    /// output's IO buffer: the drums and the transposed stems come out together.
    @Test(arguments: [0, 2205] as [AVAudioFramePosition], [4096, 512, 256])
    func transposedDrumsAlignWithTheRest(lead: AVAudioFramePosition, slice: Int) throws {
        let frames = Int(Self.rate) * 2
        let click = AudioTestSignals.click(frames: frames, at: Int(Self.rate / 2), rate: Self.rate)
        let fixture = try Fixture(vocals: click, drums: click, slice: slice)
        try fixture.rewire(Transpose(semitones: 3))
        var onsets: [Stem: Int] = [:]
        var delays = 0
        for solo in [Stem.vocals, .drums] {
            for (stem, node) in fixture.graph.nodes { node.volume = stem == solo ? 1 : 0 }
            try fixture.start(lead: lead)
            // The time pitch gives its latency only while the engine runs.
            delays = fixture.graph.drumsDelayFrames + fixture.graph.latencyFrames
            onsets[solo] = AudioTestSignals.onset(try fixture.render(Int(Self.rate * 1.5)), rate: Self.rate)
            fixture.engine.stop()
            fixture.engine.reset()
        }
        let vocals = try #require(onsets[.vocals]), drums = try #require(onsets[.drums])
        #expect(abs(vocals - drums) <= 44, "vocals \(vocals), drums \(drums)")
        let expected = (AudioTestSignals.onset(click, rate: Self.rate) ?? 0) + delays + Int(lead)
        #expect(abs(vocals - expected) <= 44, "vocals \(vocals), expected \(expected)")
    }

    @Test func crossingZeroRewiresAndBack() throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        try fixture.rewire(Transpose(semitones: 3))
        try fixture.rewire(.off)
        #expect(fixture.graph.latencyFrames == 0)
        try fixture.start()
        let out = try fixture.render(8192)
        #expect(abs(out[8000 * 2] - 0.3) < 1e-6)
    }

    @Test func seekDoesNotReplayOldAudio() throws {
        let frames = Int(Self.rate) * 2
        // The time pitch holds about 4096 frames: at the seek (1.0 s) it has read the click at 0.97 s and not
        // given it out yet; it must not come out after the seek.
        let click = AudioTestSignals.click(frames: frames, at: Int(Self.rate * 0.97), rate: Self.rate)
        let fixture = try Fixture(vocals: click, drums: [Float](repeating: 0, count: frames * 2))
        try fixture.rewire(Transpose(semitones: 3))
        try fixture.start()
        _ = try fixture.render(Int(Self.rate))
        for node in fixture.graph.nodes.values { node.stop() }
        try fixture.start(from: AVAudioFramePosition(Self.rate * 1.5))
        let after = try fixture.render(fixture.graph.drumsDelayFrames + fixture.graph.latencyFrames + 4096)
        #expect(after.map(abs).max()! < 1e-4)
    }
}
