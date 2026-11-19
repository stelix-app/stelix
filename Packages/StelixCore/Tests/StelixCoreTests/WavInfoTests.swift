// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import StelixCore

/// Helpers shared with `StemSaverTests`: real WAV stems, and two independent ways to read what
/// `WavInfo` wrote (Core Audio, and the bytes of the file).
enum WavFixture {
    static func folder(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stereo Float32 WAV as the engine writes its stems. Returns the planar samples.
    @discardableResult
    static func writeStem(_ url: URL, frames: Int = 4_410) throws -> [Float] {
        let samples = (0..<2 * frames).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        try StemFiles.writeWAV(samples, frames: frames, sampleRate: 44_100, to: url)
        return samples
    }

    /// The file's information as Core Audio reads it (the same reader as Finder, QuickTime and Logic).
    static func coreAudioInfo(_ url: URL) -> [String: String] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return [:] }
        defer { AudioFileClose(file) }
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var dictionary: Unmanaged<CFDictionary>?
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dictionary) == noErr,
              let info = dictionary?.takeRetainedValue() as? [String: Any] else { return [:] }
        return info.compactMapValues { $0 as? String }
    }

    /// The RIFF chunks in file order. Throws if a chunk runs past the end or bytes are left over.
    static func chunks(_ url: URL) throws -> [(id: String, body: Data)] {
        struct Broken: Error {}
        let data = try Data(contentsOf: url)
        func le32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        guard data.count >= 12, String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE", le32(4) == data.count - 8 else { throw Broken() }
        var result: [(String, Data)] = []
        var offset = 12
        while offset < data.count {
            guard offset + 8 <= data.count else { throw Broken() }
            let size = le32(offset + 4)
            guard offset + 8 + size <= data.count else { throw Broken() }
            result.append((String(decoding: data[offset..<offset + 4], as: UTF8.self), Data(data[offset + 8..<offset + 8 + size])))
            offset += 8 + size + size % 2
        }
        guard offset == data.count else { throw Broken() }
        return result
    }

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        return (0..<2).flatMap { channel in Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: frames)) }
    }
}

struct WavInfoTests {
    @Test func coreAudioReadsTheSoftwareAndTheComment() throws {
        let dir = try WavFixture.folder("WavInfoTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "vocals.wav")
        try WavFixture.writeStem(url)
        #expect(WavFixture.coreAudioInfo(url)[kAFInfoDictionary_Comments] == nil)

        try WavInfo.append(software: "Stelix 1.0", comment: "Stem separated by an AI model (htdemucs_6s)", to: url)

        let info = WavFixture.coreAudioInfo(url)
        #expect(info[kAFInfoDictionary_EncodingApplication] == "Stelix 1.0")
        #expect(info[kAFInfoDictionary_Comments] == "Stem separated by an AI model (htdemucs_6s)")
    }

    @Test func audioStaysTheSame() throws {
        let dir = try WavFixture.folder("WavInfoTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "drums.wav")
        let written = try WavFixture.writeStem(url)
        try WavInfo.append(software: "Stelix 1.0", comment: "Stem separated by an AI model (htdemucs_6s)", to: url)
        #expect(try WavFixture.samples(url) == written)
    }

    /// The chunk is the last one, the RIFF size covers it, and its bytes are these: texts end with a
    /// zero and are padded to an even length ("Stelix 1.0" is 11 bytes with its zero, "AI" is 3).
    @Test func chunkIsWrittenAsTheFormatAsks() throws {
        let dir = try WavFixture.folder("WavInfoTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "bass.wav")
        try WavFixture.writeStem(url)
        let before = try WavFixture.chunks(url)

        try WavInfo.append(software: "Stelix 1.0", comment: "AI", to: url)

        let after = try WavFixture.chunks(url)
        #expect(after.map(\.id) == before.map(\.id) + ["LIST"])
        #expect(after.dropLast().map(\.body) == before.map(\.body))
        var expected = Data("INFOISFT".utf8) + Data([11, 0, 0, 0]) + Data("Stelix 1.0".utf8) + Data([0, 0])
        expected += Data("ICMT".utf8) + Data([3, 0, 0, 0]) + Data("AI".utf8) + Data([0, 0])
        #expect(after.last?.body == expected)
    }

    /// The comment names the models with the same names the catalog and the README use.
    @Test func provenanceNamesTheModels() {
        #expect(StemProvenance(software: "Stelix 1.0", models: [.htdemucs6s])
            == StemProvenance(software: "Stelix 1.0", comment: "Stem separated by an AI model (htdemucs_6s)"))
        #expect(StemProvenance(software: "Stelix 1.0", models: ModelCatalog.models(for: StudioLevel.pro)).comment
            == "Stem separated by an AI model (bs_roformer_ep317, bs_roformer_sw)")
    }

    @Test func fileThatIsNotAWavIsRefusedAndLeftAsItIs() throws {
        let dir = try WavFixture.folder("WavInfoTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "text.wav")
        let text = Data("this is not a RIFF file, and it is longer than a header".utf8)
        try text.write(to: url)
        #expect(throws: WavInfo.NotAWav.self) { try WavInfo.append(software: "Stelix 1.0", comment: "AI", to: url) }
        #expect(try Data(contentsOf: url) == text)
    }

    /// A RIFF size that does not match the file (a WAV cut halfway, or with something after it):
    /// appending would put the chunk where no reader looks, so the file is refused.
    @Test func wavWhoseSizeDoesNotMatchIsRefusedAndLeftAsItIs() throws {
        let dir = try WavFixture.folder("WavInfoTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "cut.wav")
        try WavFixture.writeStem(url)
        let cut = try Data(contentsOf: url).dropLast(1_000)
        try cut.write(to: url)
        #expect(throws: WavInfo.NotAWav.self) { try WavInfo.append(software: "Stelix 1.0", comment: "AI", to: url) }
        #expect(try Data(contentsOf: url) == cut)
    }
}
