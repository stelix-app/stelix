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

        func rewire(_ transpose: Transpose, _ speed: Speed) throws {
            engine.stop()
            graph.setTranspose(transpose)
            graph.setSpeed(speed)
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

    // MARK: Speed (Task 12.1)

    /// The time pitch's reported latency is off by up to about 11 ms at 50% (measured on 28/11): the start of
    /// a sound is checked against it within 15 ms.
    static let speedTolerance = Int(rate * 0.015)

    /// Vocals and drums, the same click at 0.5 s of the file, one at a time, in slices as small as a real
    /// output's: they come out together, at the stretched time after the start delay.
    @Test(arguments: [50, 75, 125, 150], [0, 3])
    func drumsAlignWithTheRestAtSpeed(percent: Int, semitones: Int) throws {
        let frames = Int(Self.rate) * 3
        let click = AudioTestSignals.click(frames: frames, at: Int(Self.rate / 2), rate: Self.rate)
        let fixture = try Fixture(vocals: click, drums: click, slice: 512)
        let speed = Speed(percent: percent)
        try fixture.rewire(Transpose(semitones: semitones), speed)
        #expect(fixture.graph.drumsDelayFrames == 0)
        var onsets: [Stem: Int] = [:]
        var delay = 0
        for solo in [Stem.vocals, .drums] {
            for (stem, node) in fixture.graph.nodes { node.volume = stem == solo ? 1 : 0 }
            try fixture.start(lead: 2205)
            delay = fixture.graph.startDelayFrames
            onsets[solo] = AudioTestSignals.onset(try fixture.render(Int(Self.rate * 1.5)), rate: Self.rate)
            fixture.engine.stop()
            fixture.engine.reset()
        }
        let vocals = try #require(onsets[.vocals]), drums = try #require(onsets[.drums])
        #expect(abs(vocals - drums) <= 44, "vocals \(vocals), drums \(drums)")
        let clickAt = AudioTestSignals.onset(click, rate: Self.rate) ?? 0
        // The start time is in the nodes' own time, which runs `factor` per output frame: the lead is
        // stretched too.
        let expected = Int((Double(2205 + clickAt) / speed.factor).rounded()) + delay
        #expect(abs(vocals - expected) <= Self.speedTolerance, "vocals \(vocals), expected \(expected)")
    }

    /// The speed never changes the pitch: 440 Hz stays 440 Hz at 75%, and +3 semitones is still 523 Hz.
    @Test(arguments: [(0, 440.0), (3, 523.25)])
    func pitchUnchangedAtSpeed(semitones: Int, hertz: Double) throws {
        let frames = Int(Self.rate) * 3
        var sine = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let v = Float(0.3 * sin(2 * Double.pi * 440 * Double(f) / Self.rate))
            sine[f * 2] = v
            sine[f * 2 + 1] = v
        }
        let fixture = try Fixture(vocals: sine, drums: [Float](repeating: 0, count: frames * 2))
        try fixture.rewire(Transpose(semitones: semitones), Speed(percent: 75))
        try fixture.start()
        let out = try fixture.render(Int(Self.rate * 1.5))
        let measured = Self.frequency(Array(out[Int(Self.rate) * 2..<Int(Self.rate * 1.5) * 2]), rate: Self.rate)
        #expect(abs(measured - hertz) < 4, "\(measured) Hz")
    }

    /// The clock counts file frames: after a second of output, about (a second − the start delay) × speed.
    @Test(arguments: [50, 150])
    func clockNodeCountsFileFramesAtSpeed(percent: Int) throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        let speed = Speed(percent: percent)
        try fixture.rewire(.off, speed)
        try fixture.start()
        _ = try fixture.render(44_100)
        let node = fixture.graph.clockNode
        let time = try #require(node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0) })
        let heard = fixture.graph.heardFrames(clockSampleTime: time.sampleTime)
        let expected = Int((Double(44_100 - fixture.graph.startDelayFrames) * speed.factor).rounded())
        #expect(abs(Int(heard) - expected) < 1024, "\(heard), expected \(expected)")
    }

    /// A seek at 75%: nothing from before it comes out, and a click after it comes at its stretched time.
    @Test func seekAtSpeedStartsAtTheRightFrame() throws {
        let frames = Int(Self.rate) * 3
        var signal = AudioTestSignals.click(frames: frames, at: Int(Self.rate * 0.97), rate: Self.rate)
        let later = AudioTestSignals.click(frames: frames, at: Int(Self.rate * 2), rate: Self.rate)
        for i in signal.indices { signal[i] += later[i] }
        let fixture = try Fixture(vocals: signal, drums: [Float](repeating: 0, count: frames * 2))
        let speed = Speed(percent: 75)
        try fixture.rewire(Transpose(semitones: 3), speed)
        try fixture.start()
        _ = try fixture.render(Int(Self.rate * 1.2))
        for node in fixture.graph.nodes.values { node.stop() }
        try fixture.start(from: AVAudioFramePosition(Self.rate * 1.5))
        let delay = fixture.graph.startDelayFrames
        let after = try fixture.render(delay + Int(Self.rate))
        let quiet = after[0..<(delay + 4096) * 2]
        #expect(quiet.map(abs).max()! < 1e-4)
        let onset = try #require(AudioTestSignals.onset(after, rate: Self.rate))
        let expected = delay + Int((Self.rate * 0.5 / speed.factor).rounded())
        #expect(abs(onset - expected) <= Self.speedTolerance, "\(onset), expected \(expected)")
    }

    @Test func needsRewireOnlyWhenTheShapeChanges() throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        let graph = fixture.graph
        #expect(graph.needsRewire(transpose: Transpose(semitones: 3), speed: .normal))
        try fixture.rewire(Transpose(semitones: 3), .normal)
        #expect(!graph.needsRewire(transpose: Transpose(semitones: 5), speed: .normal))
        #expect(graph.needsRewire(transpose: Transpose(semitones: 3), speed: Speed(percent: 75)))
        try fixture.rewire(Transpose(semitones: 3), Speed(percent: 75))
        #expect(!graph.needsRewire(transpose: .off, speed: Speed(percent: 50)))
        try fixture.rewire(.off, Speed(percent: 50))
        #expect(graph.needsRewire(transpose: .off, speed: .normal))
        #expect(graph.shape == .stretched)
    }

    /// Back to 0 semitones and 100%: the direct sum of 1.0.0 again.
    @Test func backToNormalIsTheDirectSum() throws {
        let fixture = try Fixture(vocals: Self.constant(0.1), drums: Self.constant(0.2))
        try fixture.rewire(Transpose(semitones: 3), Speed(percent: 75))
        try fixture.rewire(.off, .normal)
        #expect(fixture.graph.latencyFrames == 0 && fixture.graph.startDelayFrames == 0)
        try fixture.start()
        let out = try fixture.render(8192)
        #expect(abs(out[8000 * 2] - 0.3) < 1e-6)
    }

    /// From the zero crossings going up, between the first and the last.
    private static func frequency(_ interleaved: [Float], rate: Double) -> Double {
        var crossings: [Int] = []
        for f in 1..<(interleaved.count / 2) where interleaved[(f - 1) * 2] < 0 && interleaved[f * 2] >= 0 {
            crossings.append(f)
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) * rate / Double(last - first)
    }
}
