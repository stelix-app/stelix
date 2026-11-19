// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct StemSaverTests {
    private static func date() -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 15, minute: 30))!
    }

    /// A test folder with the 6 stems (and a recording), plus the root where to save.
    private static func fixture() throws -> (base: URL, result: StemsResult, recording: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "StemSaverTests-\(UUID().uuidString)")
        let source = base.appending(path: "scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var files: [Stem: String] = [:]
        for stem in Stem.studio {
            let url = source.appending(path: stem.fileName)
            try Data(stem.rawValue.utf8).write(to: url)
            files[stem] = url.path
        }
        let recording = source.appending(path: "recording.wav")
        try Data("rec".utf8).write(to: recording)
        let result = StemsResult(folder: source.path, files: files, duration: 10, waveforms: [:])
        return (base, result, recording, base.appending(path: "Stelix"))
    }

    private static let english: @Sendable (Stem) -> String = { "\($0.rawValue).wav" }

    @Test func savesSixStemsInANewFolder() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav")
        #expect(folder.lastPathComponent == "2026-11-08 15.30 a")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["vocals.wav", "drums.wav", "bass.wav", "other.wav", "piano.wav", "guitar.wav"])
        #expect(try Data(contentsOf: folder.appending(path: Stem.vocals.fileName)) == Data(Stem.vocals.rawValue.utf8))
        // The temporary stems remain: the player still has them open.
        #expect(FileManager.default.fileExists(atPath: f.result.files[.vocals]!))
    }

    @Test func savesTheRecordingToo() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = try StemSaver.save(f.result, recording: f.recording, sourceName: nil, root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav")
        #expect(folder.lastPathComponent == "2026-11-08 15.30")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "recording.wav").path))
    }

    /// The names are chosen by the app, in the language of whoever uses Stelix: inside, the stems are named in English.
    @Test func saverUsesGivenNames() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let italian: [Stem: String] = [.vocals: "voce.wav", .drums: "batteria.wav", .bass: "basso.wav",
                                       .other: "altro.wav", .piano: "piano.wav", .guitar: "chitarra.wav"]
        let folder = try StemSaver.save(f.result, recording: f.recording, sourceName: nil, root: f.root, date: Self.date(),
                                        names: { italian[$0]! }, recordingName: "registrazione.wav")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == Set(italian.values).union(["registrazione.wav"]))
        #expect(try Data(contentsOf: folder.appending(path: "chitarra.wav")) == Data("guitar".utf8))
    }

    // MARK: - Provenance (the AI mark in the saved files)

    /// As `fixture`, with real WAV stems.
    private static func wavFixture() throws -> (base: URL, result: StemsResult, recording: URL, root: URL) {
        let f = try fixture()
        for stem in Stem.studio { try WavFixture.writeStem(URL(fileURLWithPath: f.result.files[stem]!)) }
        try WavFixture.writeStem(f.recording)
        return f
    }

    private static let provenance = StemProvenance(software: "Stelix 1.0", comment: "Stem separated by an AI model (htdemucs_6s)")

    @Test func savedStemsSayTheyWereSeparatedByAModel() throws {
        let f = try Self.wavFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = try StemSaver.save(f.result, recording: f.recording, sourceName: nil, root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav", provenance: Self.provenance)
        for stem in Stem.studio {
            let info = WavFixture.coreAudioInfo(folder.appending(path: "\(stem.rawValue).wav"))
            #expect(info["encoding application"] == "Stelix 1.0", "\(stem.rawValue)")
            #expect(info["comments"] == "Stem separated by an AI model (htdemucs_6s)", "\(stem.rawValue)")
        }
    }

    /// The recording is the audio as it was captured: no model touched it, so it carries no mark.
    @Test func savedRecordingIsNotMarked() throws {
        let f = try Self.wavFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = try StemSaver.save(f.result, recording: f.recording, sourceName: nil, root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav", provenance: Self.provenance)
        #expect(try Data(contentsOf: folder.appending(path: "recording.wav")) == Data(contentsOf: f.recording))
    }

    /// Only the copies are marked: the player has the temporary stems open.
    @Test func temporaryStemsAreNotChanged() throws {
        let f = try Self.wavFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let before = try Stem.studio.map { try Data(contentsOf: URL(fileURLWithPath: f.result.files[$0]!)) }
        _ = try StemSaver.save(f.result, recording: nil, sourceName: nil, root: f.root, date: Self.date(),
                               names: Self.english, recordingName: "recording.wav", provenance: Self.provenance)
        let after = try Stem.studio.map { try Data(contentsOf: URL(fileURLWithPath: f.result.files[$0]!)) }
        #expect(after == before)
    }

    /// A stem that cannot carry the mark is not saved without it: the save fails and leaves nothing.
    @Test func stemThatCannotBeMarkedFailsTheSave() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect(throws: (any Error).self) {
            try StemSaver.save(f.result, recording: nil, sourceName: nil, root: f.root, date: Self.date(),
                               names: Self.english, recordingName: "recording.wav", provenance: Self.provenance)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.root.path)) ?? []).isEmpty)
    }

    @Test func failureLeavesNoFolder() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try FileManager.default.removeItem(atPath: f.result.files[.drums]!)
        #expect(throws: (any Error).self) {
            try StemSaver.save(f.result, recording: nil, sourceName: "a.mp3", root: f.root, date: Self.date(),
                                        names: Self.english, recordingName: "recording.wav")
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.root.path)) ?? []).isEmpty)
    }

    /// A full disk is told apart from other errors: copyItem throws `fileWriteOutOfSpace` with `ENOSPC`
    /// underneath (seen on a full 10 MB APFS image), a raw write throws `ENOSPC`.
    @Test func outOfSpaceIsRecognized() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(StemSaver.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                                               userInfo: [NSUnderlyingErrorKey: posix])))
        #expect(StemSaver.isOutOfSpace(posix))
        #expect(StemSaver.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                               userInfo: [NSUnderlyingErrorKey: posix])))
        #expect(!StemSaver.isOutOfSpace(CocoaError(.fileNoSuchFile)))
        #expect(!StemSaver.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }
}
