// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import StelixCore

/// Stereo Float32 WAVs for the save tests, written and read back interleaved.
enum TestWAV {
    static let rate = 44_100.0

    static func write(_ interleaved: [Float], to url: URL) throws {
        let frames = interleaved.count / 2
        var planar = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            planar[f] = interleaved[f * 2]
            planar[frames + f] = interleaved[f * 2 + 1]
        }
        try StemFiles.writeWAV(planar, frames: frames, sampleRate: rate, to: url)
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, file.length)))!
        try file.read(into: buffer)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        return (0..<Int(buffer.frameLength)).flatMap { [l[$0], r[$0]] }
    }

    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct StemTransposerTests {
    private static func transpose(_ input: [Float], semitones: Int, speed: Speed = .normal, cancel: SaveCancel? = nil,
                                  progress: (Int) -> Void = { _ in }) throws -> [Float] {
        let folder = try TestWAV.folder("StemTransposerTests")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "in.wav"), destination = folder.appending(path: "out.wav")
        try TestWAV.write(input, to: source)
        try StemTransposer.transpose(source, to: destination, semitones: semitones, speed: speed, cancel: cancel,
                                     progress: progress)
        return try TestWAV.read(destination)
    }

    @Test func keepsTheLength() throws {
        let input = AudioTestSignals.click(frames: Int(TestWAV.rate * 3), at: 1000, rate: TestWAV.rate)
        #expect(try Self.transpose(input, semitones: 3).count == input.count)
    }

    @Test func clickStaysInPlace() throws {
        let input = AudioTestSignals.click(frames: Int(TestWAV.rate * 3), at: Int(TestWAV.rate), rate: TestWAV.rate)
        let output = try Self.transpose(input, semitones: 3)
        let expected = try #require(AudioTestSignals.onset(input, rate: TestWAV.rate))
        let got = try #require(AudioTestSignals.onset(output, rate: TestWAV.rate))
        #expect(abs(got - expected) <= 44)
    }

    @Test func fileShorterThanTheLatencyKeepsItsLength() throws {
        let input = [Float](repeating: 0.1, count: 1000 * 2)
        #expect(try Self.transpose(input, semitones: -5).count == input.count)
    }

    @Test func cancelStopsAndThrows() throws {
        let cancel = SaveCancel()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try Self.transpose([Float](repeating: 0.1, count: 44_100 * 2), semitones: 3, cancel: cancel)
        }
    }

    @Test func progressReachesTheEnd() throws {
        var values: [Int] = []
        let frames = Int(TestWAV.rate * 2)
        _ = try Self.transpose([Float](repeating: 0.1, count: frames * 2), semitones: 3) { values.append($0) }
        #expect(values.last == frames)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // MARK: Speed (Task 12.1)

    @Test(arguments: [50, 75, 125])
    func lengthAtSpeed(percent: Int) throws {
        let input = [Float](repeating: 0.1, count: 88_200 * 2)
        let expected = Int((88_200 / Speed(percent: percent).factor).rounded())
        #expect(try Self.transpose(input, semitones: 0, speed: Speed(percent: percent)).count == expected * 2)
    }

    /// The time pitch's reported latency is off by up to about 11 ms (measured in the player): within 15 ms.
    @Test(arguments: [50, 125], [0, 3])
    func clickLandsAtTheStretchedFrame(percent: Int, semitones: Int) throws {
        let input = AudioTestSignals.click(frames: Int(TestWAV.rate * 2), at: Int(TestWAV.rate), rate: TestWAV.rate)
        let output = try Self.transpose(input, semitones: semitones, speed: Speed(percent: percent))
        let source = try #require(AudioTestSignals.onset(input, rate: TestWAV.rate))
        let got = try #require(AudioTestSignals.onset(output, rate: TestWAV.rate))
        let expected = Int((Double(source) / Speed(percent: percent).factor).rounded())
        #expect(abs(got - expected) <= Int(TestWAV.rate * 0.015), "\(got), expected \(expected)")
    }

    @Test func shortFileAtSpeedHasTheStretchedLength() throws {
        let input = [Float](repeating: 0.1, count: 2000 * 2)
        #expect(try Self.transpose(input, semitones: -5, speed: Speed(percent: 50)).count == 4000 * 2)
    }

    /// At 100% nothing changes: the same samples as before the speed existed.
    @Test func normalSpeedIsTheOldPath() throws {
        let input = AudioTestSignals.click(frames: Int(TestWAV.rate), at: 10_000, rate: TestWAV.rate)
        #expect(try Self.transpose(input, semitones: 3, speed: .normal) == Self.transpose(input, semitones: 3))
    }

    @Test func cancelAtSpeedThrows() throws {
        let cancel = SaveCancel()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try Self.transpose([Float](repeating: 0.1, count: 44_100 * 2), semitones: 0, speed: Speed(percent: 75),
                                   cancel: cancel)
        }
    }

    @Test func progressAtSpeedReachesTheEnd() throws {
        var values: [Int] = []
        let frames = Int(TestWAV.rate * 2)
        _ = try Self.transpose([Float](repeating: 0.1, count: frames * 2), semitones: 0, speed: Speed(percent: 60)) {
            values.append($0)
        }
        #expect(values.last == frames)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

struct StemSaverTransposeTests {
    private static func date() -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 15, minute: 30))!
    }

    /// 6 real stems, 1 s each, plus a recording, and the root where to save.
    private static func fixture() throws -> (base: URL, result: StemsResult, recording: URL, root: URL) {
        let base = try TestWAV.folder("StemSaverTransposeTests")
        var files: [Stem: String] = [:]
        for (index, stem) in Stem.studio.enumerated() {
            let url = base.appending(path: stem.fileName)
            try TestWAV.write(AudioTestSignals.click(frames: 44_100, at: 10_000 + index * 100, rate: TestWAV.rate), to: url)
            files[stem] = url.path
        }
        let recording = base.appending(path: "recording.wav")
        try TestWAV.write(AudioTestSignals.click(frames: 44_100, at: 5000, rate: TestWAV.rate), to: recording)
        return (base, StemsResult(folder: base.path, files: files, duration: 1, waveforms: [:]), recording,
                base.appending(path: "Stelix"))
    }

    private static let english: @Sendable (Stem) -> String = { "\($0.rawValue).wav" }

    @Test func offSavesTodaysCopy() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav", transpose: .off)
        #expect(folder.lastPathComponent == "2026-11-08 15.30 a")
        for stem in Stem.studio {
            #expect(try Data(contentsOf: folder.appending(path: "\(stem.rawValue).wav"))
                    == Data(contentsOf: URL(fileURLWithPath: f.result.files[stem]!)))
        }
    }

    @Test func transposedSaveCopiesDrumsAndRecording() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = try StemSaver.save(f.result, recording: f.recording, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav", transpose: Transpose(semitones: 3))
        #expect(folder.lastPathComponent == "2026-11-08 15.30 a +3 st")
        #expect(try Data(contentsOf: folder.appending(path: "drums.wav")) == Data(contentsOf: URL(fileURLWithPath: f.result.files[.drums]!)))
        #expect(try Data(contentsOf: folder.appending(path: "recording.wav")) == Data(contentsOf: f.recording))
        for stem in Stem.studio where stem != .drums {
            let source = try TestWAV.read(URL(fileURLWithPath: f.result.files[stem]!))
            let saved = try TestWAV.read(folder.appending(path: "\(stem.rawValue).wav"))
            #expect(saved.count == source.count)
            #expect(saved != source)
        }
    }

    /// The app always passes the provenance: the stems written block by block take it too, and stay readable.
    @Test func transposedStemsTakeTheProvenance() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let provenance = StemProvenance(software: "Stelix 1.1", comment: "Stem separated by an AI model (test)")
        let folder = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav", provenance: provenance,
                                        transpose: Transpose(semitones: 3))
        for stem in Stem.studio {
            let url = folder.appending(path: "\(stem.rawValue).wav")
            let info = WavFixture.coreAudioInfo(url)
            #expect(info["encoding application"] == "Stelix 1.1", "\(stem.rawValue)")
            #expect(info["comments"] == "Stem separated by an AI model (test)", "\(stem.rawValue)")
            #expect(try TestWAV.read(url).count == 44_100 * 2, "\(stem.rawValue)")
        }
    }

    @Test func cancelledSaveLeavesNoFolder() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let cancel = SaveCancel()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                   names: Self.english, recordingName: "recording.wav", transpose: Transpose(semitones: 3),
                                   cancel: cancel)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: f.root.path))?.isEmpty ?? true)
    }

    @Test func progressGoesToOne() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let seen = Mutex<[Double]>([])
        _ = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                               names: Self.english, recordingName: "recording.wav", transpose: Transpose(semitones: -2),
                               progress: { value in seen.withLock { $0.append(value) } })
        let values = seen.withLock { $0 }
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // MARK: Speed (Task 12.1)

    /// All 6 stems stretched and in time; the recording as it was.
    @Test func speedSaveStretchesEveryStem() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let click = AudioTestSignals.click(frames: 44_100, at: 22_050, rate: TestWAV.rate)
        for stem in [Stem.drums, .vocals] { try TestWAV.write(click, to: URL(fileURLWithPath: f.result.files[stem]!)) }
        let seen = Mutex<[Double]>([])
        let folder = try StemSaver.save(f.result, recording: f.recording, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav",
                                        transpose: Transpose(semitones: 3), speed: Speed(percent: 75),
                                        progress: { value in seen.withLock { $0.append(value) } })
        #expect(folder.lastPathComponent == "2026-11-08 15.30 a +3 st 75%")
        #expect(try Data(contentsOf: folder.appending(path: "recording.wav")) == Data(contentsOf: f.recording))
        let length = Int((44_100 / 0.75).rounded())
        for stem in Stem.studio {
            #expect(try TestWAV.read(folder.appending(path: "\(stem.rawValue).wav")).count == length * 2, "\(stem.rawValue)")
        }
        let drums = try #require(AudioTestSignals.onset(TestWAV.read(folder.appending(path: "drums.wav")), rate: TestWAV.rate))
        let vocals = try #require(AudioTestSignals.onset(TestWAV.read(folder.appending(path: "vocals.wav")), rate: TestWAV.rate))
        #expect(abs(drums - vocals) <= 44, "drums \(drums), vocals \(vocals)")
        #expect(seen.withLock { $0 }.last == 1)
    }

    /// The drums are slowed down, never transposed.
    @Test func speedSaveKeepsTheDrumsPitch() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        var tone = [Float](repeating: 0, count: 44_100 * 2)
        for frame in 0..<44_100 {
            let v = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / TestWAV.rate))
            tone[frame * 2] = v
            tone[frame * 2 + 1] = v
        }
        try TestWAV.write(tone, to: URL(fileURLWithPath: f.result.files[.drums]!))
        let folder = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav",
                                        transpose: Transpose(semitones: 3), speed: Speed(percent: 75))
        let drums = try TestWAV.read(folder.appending(path: "drums.wav"))
        let window = Array(drums[Int(TestWAV.rate * 0.3) * 2..<Int(TestWAV.rate * 1.0) * 2])
        #expect(abs(Self.frequency(window) - 440) < 4, "\(Self.frequency(window)) Hz")
    }

    @Test func cancelAtSpeedRemovesTheFolder() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let cancel = SaveCancel()
        cancel.cancel()
        #expect(throws: CancellationError.self) {
            _ = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                   names: Self.english, recordingName: "recording.wav", speed: Speed(percent: 75),
                                   cancel: cancel)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: f.root.path))?.isEmpty ?? true)
    }

    /// From the zero crossings going up, between the first and the last.
    private static func frequency(_ interleaved: [Float]) -> Double {
        var crossings: [Int] = []
        for f in 1..<(interleaved.count / 2) where interleaved[(f - 1) * 2] < 0 && interleaved[f * 2] >= 0 {
            crossings.append(f)
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) * TestWAV.rate / Double(last - first)
    }
}
