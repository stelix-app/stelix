// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// What a saved stem says about where it comes from: the software that made it and a sentence
/// saying that a model separated it. It is the machine-readable mark that art. 50(2) of the EU AI Act
/// asks of audio "generated or manipulated" by an AI system. Whether stem separation falls under it
/// is not settled (the Commission's guidelines do not name it), so the files carry the mark anyway.
public struct StemProvenance: Sendable, Equatable {
    public var software: String
    public var comment: String

    public init(software: String, comment: String) {
        self.software = software
        self.comment = comment
    }

    /// `software` is the app's name and version ("Stelix 1.0"); `models` are the ones that made the stems.
    public init(software: String, models: [ModelID]) {
        self.init(software: software,
                  comment: "Stem separated by an AI model (\(models.map(\.rawValue).joined(separator: ", ")))")
    }
}

/// Writes the software and a comment in the `LIST/INFO` chunk of a WAV file, where Finder, QuickTime
/// and audio editors read them (`ISFT` and `ICMT`).
public enum WavInfo {
    /// The file is not a RIFF/WAVE whose size matches its header: nothing was written.
    public struct NotAWav: Error, Equatable {}

    /// Appends the chunk after the audio and updates the RIFF size. The audio is not touched.
    public static func append(software: String, comment: String, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        let size = try handle.seekToEnd()
        // The header's size must be the file's: a chunk appended to a file that is cut, or that has
        // something after its last chunk, would end up where no reader looks.
        guard header.count == 12, header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8),
              size % 2 == 0, UInt64(littleEndian32(header, at: 4)) + 8 == size
        else { throw NotAWav() }

        let info = Data("INFO".utf8) + text("ISFT", software) + text("ICMT", comment)
        let chunk = Data("LIST".utf8) + littleEndian(UInt32(info.count)) + info
        guard size + UInt64(chunk.count) - 8 <= UInt64(UInt32.max) else { throw NotAWav() }
        try handle.write(contentsOf: chunk)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndian(UInt32(size + UInt64(chunk.count) - 8)))
    }

    /// One INFO entry: the text ends with a zero, and an odd length gets a padding byte that the
    /// size does not count.
    private static func text(_ id: String, _ value: String) -> Data {
        var bytes = Data(value.utf8.filter { $0 != 0 })
        bytes.append(0)
        var entry = Data(id.utf8) + littleEndian(UInt32(bytes.count)) + bytes
        if bytes.count % 2 == 1 { entry.append(0) }
        return entry
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[start + $1]) << (8 * UInt32($1)) }
    }
}
