// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// The folder of a Studio job: `~/Music/Stelix/YYYY-MM-DD HH.mm[ source]`, with " 2",
/// " 3"… if there is already one in the same minute. It holds the recording and the 6 stems.
public enum StudioFolder {
    public static let defaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/Stelix")

    /// Creates the folder and returns it. `sourceName` is the name of the loaded file: the
    /// extension is removed and "/" and ":" become "-". A transpose adds " +3 st" after it, a speed
    /// " 75%" after that, before any " 2". If it cannot be created: `EngineFailure` "folder".
    public static func make(root: URL = defaultRoot, date: Date, sourceName: String?,
                            transpose: Transpose = .off, speed: Speed = .normal) throws(EngineFailure) -> URL {
        let failure = EngineFailure(.musicFolder)
        let fileManager = FileManager.default
        do { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) } catch { throw failure }

        var base = stamp(date)
        if let source = sourceName.map(sanitized), !source.isEmpty {
            base += " " + source
        }
        base += transpose.folderSuffix + speed.folderSuffix
        var index = 1
        while true {
            let folder = root.appending(path: index == 1 ? base : "\(base) \(index)", directoryHint: .isDirectory)
            do {
                // Without intermediate the creation fails if the folder already exists: no race between
                // the check and the creation.
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch CocoaError.fileWriteFileExists {
                index += 1
            } catch {
                throw failure
            }
        }
    }

    static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return String(format: "%04d", parts.year ?? 0) + "-" + two(parts.month) + "-" + two(parts.day)
            + " " + two(parts.hour) + "." + two(parts.minute)
    }

    static func sanitized(_ name: String) -> String {
        var stem = name
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            stem = String(stem[..<dot])
        }
        stem = stem.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // NAME_MAX is 255 bytes: with the date (17), the transpose and speed suffixes (at most 12,
        // " -12 st 150%") and a " N" about 220 bytes remain; the source is kept under 200, in whole characters, counted in the
        // decomposed form that reaches the file system.
        while stem.decomposedStringWithCanonicalMapping.utf8.count > maxSourceBytes { stem.removeLast() }
        return stem.trimmingCharacters(in: .whitespaces)
    }

    static let maxSourceBytes = 200
}
