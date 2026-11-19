// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct ModelCatalogTests {
    @Test func everyLevelHasModels() {
        let shipped = Set(ModelCatalog.shipped.packages.map(\.id))
        for level in LiveLevel.allCases {
            let ids = ModelCatalog.models(for: level)
            #expect(!ids.isEmpty)
            #expect(ids.allSatisfy(shipped.contains))
        }
        for level in StudioLevel.allCases {
            let ids = ModelCatalog.models(for: level)
            #expect(!ids.isEmpty)
            #expect(ids.allSatisfy(shipped.contains))
        }
        #expect(ModelCatalog.models(for: LiveLevel.intermediate) == [.htdemucs])
        #expect(ModelCatalog.models(for: LiveLevel.pro) == [.htdemucsFT])
        #expect(ModelCatalog.models(for: StudioLevel.base) == [.htdemucs6s])
        #expect(ModelCatalog.models(for: StudioLevel.pro) == [.roformerVocals, .roformerSW])
        #expect(Set(ModelCatalog.shipped.packages.map(\.id)) == Set(ModelID.allCases))
    }

    @Test func shippedFilesHaveHexDigests() {
        let hex = Set("0123456789abcdef")
        let files = ModelCatalog.shipped.packages.flatMap(\.files)
        #expect(files.count == 10)
        for file in files {
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy(hex.contains), "\(file.name)")
            #expect(file.url.scheme == "https", "\(file.name)")
            #expect(file.url.lastPathComponent == file.name, "\(file.name)")
            #expect(file.size > 0, "\(file.name)")
        }
        // No repeated fingerprint: `file(sha256:)` must give a single file.
        #expect(Set(files.map(\.sha256)).count == files.count)
        let htdemucs = ModelCatalog.shipped.package(.htdemucs)
        #expect(htdemucs.size == 168_005_865 + 4_215)
        #expect(htdemucs.license == .demucsUnclear)
        #expect(ModelCatalog.shipped.package(.roformerSW).license == .undeclaredUnverified)
    }

    @Test func fileBySHA() {
        let catalog = ModelCatalog.shipped
        let file = catalog.file(sha256: "339d267a7a6983a11eedbdc00413c602a65e9b9103f695fb5c2b2a481cd9d297")
        #expect(file?.name == "htdemucs.safetensors")
        #expect(file?.folder == .demucs)
        #expect(catalog.file(sha256: String(repeating: "0", count: 64)) == nil)
        #expect(catalog.package(containing: "BS-Roformer-SW.yaml")?.id == .roformerSW)
    }
}

struct FileDigestTests {
    @Test func sha256OfKnownText() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "FileDigestTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try FileDigest.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// More than one 1 MB block: the digest must join the blocks, not take the last one.
    @Test func sha256SpansBlocks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "FileDigestTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 2_500_000).write(to: url)
        let small = FileManager.default.temporaryDirectory.appending(path: "FileDigestTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: small) }
        try Data(repeating: 0x61, count: 500_000).write(to: small)
        #expect(try FileDigest.sha256(of: url) != FileDigest.sha256(of: small))
        // `head -c 2500000 /dev/zero | tr '\0' a | shasum -a 256`
        #expect(try FileDigest.sha256(of: url) == Self.twoAndAHalfMillionA)
    }

    private static let twoAndAHalfMillionA = "38a637965059125eeb67f54c30e7f48a61859a467a800ba09740ba48a924f2b9"
}
