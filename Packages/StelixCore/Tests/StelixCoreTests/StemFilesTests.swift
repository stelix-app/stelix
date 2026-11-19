// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import Testing
@testable import StelixCore

struct StemFilesTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "StemFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 6 stems of `frames` frames, each constant at the value `value + index / 10`.
    private static func stems(frames: Int, value: Float) -> [(Stem, [Float])] {
        Stem.studio.enumerated().map { index, stem in
            (stem, [Float](repeating: value + Float(index) / 10, count: 2 * frames))
        }
    }

    private static func firstSample(_ url: URL) throws -> (Float, Int) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (buffer.floatChannelData![0][0], Int(file.length))
    }

    private static func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func writesSixStemsWithFinalNames() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try StemFiles.write(Self.stems(frames: 1_000, value: 0.1), frames: 1_000, into: folder) { false }
        #expect(try Self.names(folder) == Stem.studio.map(\.fileName).sorted())
        #expect(files.count == 6)
        let (sample, frames) = try Self.firstSample(files[.vocals]!)
        #expect(frames == 1_000)
        #expect(abs(sample - 0.1) < 1e-6)
    }

    /// The stems are written to `.<name>.partial` first: the format must not come from that extension
    /// (AVAudioFile would write a CAF), or Save cannot add its metadata and DAWs get a CAF named `.wav`.
    @Test func stemsAreRealWavFilesThatSaveCanTag() throws {
        let folder = try Self.folder()
        let music = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: music)
        }
        let files = try StemFiles.write(Self.stems(frames: 1_000, value: 0.1), frames: 1_000, into: folder) { false }
        for url in files.values {
            let header = try Data(contentsOf: url).prefix(12)
            #expect(header.prefix(4) == Data("RIFF".utf8) && header.suffix(4) == Data("WAVE".utf8), "\(url.lastPathComponent)")
        }
        let result = StemsResult(folder: folder.path, files: files.mapValues(\.path), duration: 1_000 / 44_100,
                                 waveforms: [:])
        let saved = try StemSaver.save(result, recording: nil, sourceName: nil, root: music, date: Date(),
                                       names: { $0.fileName }, recordingName: "recording.wav",
                                       provenance: StemProvenance(software: "Stelix test", models: []))
        #expect(try Self.names(saved) == Stem.studio.map(\.fileName).sorted())
    }

    @Test func replacesExistingStems() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try StemFiles.write(Self.stems(frames: 500, value: 0.1), frames: 500, into: folder) { false }
        let files = try StemFiles.write(Self.stems(frames: 800, value: 0.3), frames: 800, into: folder) { false }
        let (sample, frames) = try Self.firstSample(files[.vocals]!)
        #expect(frames == 800)
        #expect(abs(sample - 0.3) < 1e-6)
        #expect(try Self.names(folder) == Stem.studio.map(\.fileName).sorted())
    }

    @Test func cancelKeepsOldStemsAndLeavesNoPartials() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("registrazione".utf8).write(to: folder.appending(path: "recording.wav"))
        _ = try StemFiles.write(Self.stems(frames: 500, value: 0.1), frames: 500, into: folder) { false }
        var checks = 0
        do {
            _ = try StemFiles.write(Self.stems(frames: 800, value: 0.3), frames: 800, into: folder) {
                checks += 1
                return checks > 3
            }
            Issue.record("it should have been cancelled")
        } catch {
            #expect(error == EngineFailure(.separationCancelled))
        }
        #expect(try Self.names(folder) == (Stem.studio.map(\.fileName) + ["recording.wav"]).sorted())
        for stem in Stem.studio {
            let (sample, frames) = try Self.firstSample(folder.appending(path: stem.fileName))
            #expect(frames == 500, "\(stem)")
            #expect(sample < 0.25 + Float(Stem.studio.firstIndex(of: stem)!) / 10, "\(stem)")
        }
    }

    /// A rename that fails halfway (the third): the previous stems all come back, and nothing
    /// temporary remains.
    @Test func failedRenameMidwayRestoresTheOldSet() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var pairs: [(partial: URL, final: URL)] = []
        for (index, stem) in Stem.studio.enumerated() {
            let final = folder.appending(path: stem.fileName)
            let partial = folder.appending(path: ".\(stem.fileName).partial")
            // The last one was not there before: after the restore it must not be there.
            if index < 5 { try Data("old".utf8).write(to: final) }
            try Data("new".utf8).write(to: partial)
            pairs.append((partial, final))
        }
        var calls = 0
        #expect(throws: StemFiles.writeFailed) {
            try StemFiles.commit(pairs) { from, to in
                if from.hasSuffix(".partial") { calls += 1 }
                return calls == 3 && from.hasSuffix(".partial") ? -1 : Darwin.rename(from, to)
            }
        }
        for (index, pair) in pairs.enumerated() {
            if index < 5 {
                #expect(try String(contentsOf: pair.final, encoding: .utf8) == "old")
            } else {
                #expect(!FileManager.default.fileExists(atPath: pair.final.path))
            }
        }
        #expect(try Self.names(folder).allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func commitReplacesAndLeavesNoBackups() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let final = folder.appending(path: "vocals.wav")
        let partial = folder.appending(path: ".vocals.wav.partial")
        try Data("old".utf8).write(to: final)
        try Data("new".utf8).write(to: partial)
        try StemFiles.commit([(partial, final)])
        #expect(try String(contentsOf: final, encoding: .utf8) == "new")
        #expect(try Self.names(folder) == ["vocals.wav"])
    }
}
