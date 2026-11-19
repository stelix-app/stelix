// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct StudioFolderTests {
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 30))!
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "StudioFolderTests-\(UUID().uuidString)/Stelix")
    }

    @Test func namesWithDateAndSource() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = try StudioFolder.make(root: root, date: Self.date(2026, 11, 7, 13, 5), sourceName: "Song.mp3")
        #expect(folder.lastPathComponent == "2026-11-07 13.05 Song")
        #expect(folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func namesWithDateOnly() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = try StudioFolder.make(root: root, date: Self.date(2026, 1, 2, 9, 0), sourceName: nil)
        #expect(folder.lastPathComponent == "2026-01-02 09.00")
    }

    @Test func sameMinuteGetsSuffix() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let date = Self.date(2026, 11, 7, 13, 5)
        let names = try (0..<3).map { _ in try StudioFolder.make(root: root, date: date, sourceName: "Song.mp3").lastPathComponent }
        #expect(names == ["2026-11-07 13.05 Song", "2026-11-07 13.05 Song 2", "2026-11-07 13.05 Song 3"])
    }

    @Test func sanitizesSlashAndColon() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = try StudioFolder.make(root: root, date: Self.date(2026, 11, 7, 13, 5), sourceName: "a/b:c.wav")
        #expect(folder.lastPathComponent == "2026-11-07 13.05 a-b-c")
    }

    /// The folder name comes from the name of the user's file: whatever it is, the folder is created
    /// directly inside the root, never above it or deeper.
    @Test(arguments: ["../../x.wav", "..", ".", "a/../../b", "/etc/passwd", ":::", "..:..:x", "🎵 canzone 🎸.wav",
                      "a\nb.wav", "~/x.wav", "-rf.wav", ".hidden"])
    func hostileSourceNamesStayDirectlyInsideTheRoot(name: String) throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = try StudioFolder.make(root: root, date: Self.date(2026, 11, 7, 13, 5), sourceName: name)
        #expect(folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(folder.lastPathComponent.hasPrefix("2026-11-07 13.05"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [folder.lastPathComponent])
    }

    /// A very long name (600 UTF-8 bytes) would exceed NAME_MAX (255 bytes): the source is truncated,
    /// without splitting a character, and there is still room for " 2", " 3"…
    @Test func longSourceNameIsTruncatedUnderNameMax() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let long = String(repeating: "è", count: 300) + ".mp3"
        let date = Self.date(2026, 11, 7, 13, 5)
        let first = try StudioFolder.make(root: root, date: date, sourceName: long).lastPathComponent
        let second = try StudioFolder.make(root: root, date: date, sourceName: long).lastPathComponent
        // The file system receives the decomposed form (NFD): "è" weighs 3 bytes, not 2.
        #expect(first.decomposedStringWithCanonicalMapping.utf8.count <= 220)
        #expect(first.hasPrefix("2026-11-07 13.05 èèè"))
        #expect(first.allSatisfy { $0 == "è" || !$0.isLetter })
        #expect(second == first + " 2")
    }

    @Test func unwritableRootThrowsFolderFailure() throws {
        // The root sits under a file: the folder cannot be created.
        let base = FileManager.default.temporaryDirectory.appending(path: "StudioFolderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base)
        #expect(throws: EngineFailure(.musicFolder)) {
            try StudioFolder.make(root: base.appending(path: "Stelix"), date: Date(), sourceName: "Song.mp3")
        }
    }
}
