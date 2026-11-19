// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import StelixCore

struct MediaDropTests {
    @Test func audioAndVideoAreAccepted() {
        #expect(MediaDrop.accepts(UTType.mp3))
        #expect(MediaDrop.accepts(UTType.wav))
        #expect(MediaDrop.accepts(UTType.mpeg4Movie))
        #expect(MediaDrop.accepts(UTType.quickTimeMovie))
    }

    @Test func knownNonMediaIsRefused() {
        #expect(!MediaDrop.accepts(UTType.pdf))
        #expect(!MediaDrop.accepts(UTType.png))
        #expect(!MediaDrop.accepts(UTType.plainText))
        #expect(!MediaDrop.accepts(UTType.folder))
    }

    @Test func unknownTypeIsLeftToTheLoader() {
        #expect(MediaDrop.accepts(UTType?.none))
        #expect(MediaDrop.accepts(UTType(filenameExtension: "v2")))
    }

    @Test func filesOnDiskByName() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MediaDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.mp3", "Mr. Brown", "b.pdf"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        #expect(MediaDrop.accepts(dir.appending(path: "a.mp3")))
        #expect(MediaDrop.accepts(dir.appending(path: "Mr. Brown")))
        #expect(!MediaDrop.accepts(dir.appending(path: "b.pdf")))
        #expect(!MediaDrop.accepts(dir))
    }
}
