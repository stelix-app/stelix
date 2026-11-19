// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CryptoKit
import Foundation
import Testing
@testable import StelixCore

struct ModelStoreTests {
    private static let rawConfig = """
    {"kwargs": {"segment": {"__type__": "fraction", "numerator": 39, "denominator": 5}, "channels": 48},
     "per_model_kwargs": [{"segment": {"__type__": "fraction", "numerator": 39, "denominator": 5}}]}
    """

    private static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fake catalog with the fingerprints of short texts, with the same file names as the real one.
    private static let contents: [String: String] = [
        "htdemucs.safetensors": "pesi",
        "htdemucs_config.json": rawConfig,
        "htdemucs_6s.safetensors": "sei",
        "htdemucs_6s_config.json": rawConfig + " ",
        "BS-Roformer-SW.ckpt": "sw",
        "BS-Roformer-SW.yaml": "sw yaml",
        "model_bs_roformer_ep_317_sdr_12.9755.ckpt": "ep317",
        "model_bs_roformer_ep_317_sdr_12.9755.yaml": "ep317 yaml",
    ]

    private static let catalog: ModelCatalog = {
        func file(_ name: String, _ folder: ModelFolder) -> ModelFile {
            let text = contents[name]!
            return ModelFile(name: name, folder: folder, url: URL(string: "https://example.com/\(name)")!,
                             sha256: sha(text), size: Int64(text.utf8.count))
        }
        func package(_ id: ModelID, _ names: [String], _ folder: ModelFolder) -> ModelPackage {
            ModelPackage(id: id, files: names.map { file($0, folder) }, author: "a", source: "example.com", license: .undeclared)
        }
        return ModelCatalog(packages: [
            package(.htdemucs, ["htdemucs.safetensors", "htdemucs_config.json"], .demucs),
            package(.htdemucs6s, ["htdemucs_6s.safetensors", "htdemucs_6s_config.json"], .demucs),
            package(.roformerSW, ["BS-Roformer-SW.ckpt", "BS-Roformer-SW.yaml"], .roformer),
            package(.roformerVocals, ["model_bs_roformer_ep_317_sdr_12.9755.ckpt", "model_bs_roformer_ep_317_sdr_12.9755.yaml"], .roformer),
        ])
    }()

    /// Temporary folders: two sources (like ~/.cache/demucs-mlx and ~/.cache/mlx-audio-separator/models)
    /// and an empty destination.
    private struct Fixture {
        let root: URL
        let demucsCache: URL
        let roformerCache: URL
        let destination: URL
        var store: ModelStore { ModelStore(destination: destination, sources: [demucsCache, roformerCache], catalog: ModelStoreTests.catalog) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "ModelStoreTests-\(UUID().uuidString)")
            demucsCache = root.appending(path: "demucs-mlx")
            roformerCache = root.appending(path: "mlx-audio-separator/models")
            destination = root.appending(path: "Stelix/Models")
            for dir in [demucsCache, roformerCache] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        /// The file in the source with the catalog's content, or with `text` if given.
        func put(_ name: String, in dir: URL, _ text: String? = nil) throws {
            try Data((text ?? ModelStoreTests.contents[name]!).utf8).write(to: dir.appending(path: name))
        }

        func names(_ dir: String) -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: destination.appending(path: dir).path)) ?? [])
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func putSW(_ fx: Fixture) throws {
        try fx.put("BS-Roformer-SW.ckpt", in: fx.roformerCache)
        try fx.put("BS-Roformer-SW.yaml", in: fx.roformerCache)
    }

    /// A model removed in Settings stays removed: no copy from `~/.cache` comes back on its own
    /// (on the developer's Mac a removed htdemucs reappeared as soon as the Live was opened).
    @Test func defaultStoreImportsFromNowhere() {
        #expect(ModelStore().sources.isEmpty)
    }

    @Test func importsFromCacheWhenHashMatches() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.put("htdemucs.safetensors", in: fx.demucsCache)
        try fx.put("htdemucs_config.json", in: fx.demucsCache)
        #expect(!fx.store.isInstalled(.htdemucs))

        try fx.store.ensureInstalled([.htdemucs])
        #expect(fx.store.isInstalled(.htdemucs))
        #expect(fx.names("demucs") == ["htdemucs.safetensors", "htdemucs_config.json"])
        let pair = try fx.store.demucsWeights("htdemucs")
        #expect(try String(contentsOf: pair.weights, encoding: .utf8) == "pesi")
    }

    @Test func cacheFileWithWrongHashIsIgnored() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.put("htdemucs.safetensors", in: fx.demucsCache, "pesi rovinati")
        try fx.put("htdemucs_config.json", in: fx.demucsCache)

        #expect(throws: ModelStoreError.missing(.htdemucs)) { try fx.store.ensureInstalled([.htdemucs]) }
        #expect(!fx.store.isInstalled(.htdemucs))
        // The right config is imported, the wrong weights are not, and nothing temporary remains.
        #expect(fx.names("demucs") == ["htdemucs_config.json"])
        #expect(throws: ModelStoreError.missing(.htdemucs)) { try fx.store.demucsWeights("htdemucs") }
    }

    @Test func missingNamesTheFirstAbsentPackage() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try putSW(fx)
        #expect(throws: ModelStoreError.missing(.roformerVocals)) {
            try fx.store.ensureInstalled(ModelCatalog.models(for: StudioLevel.pro))
        }
        #expect(fx.store.isInstalled(.roformerSW))
        #expect(!fx.store.isInstalled(.roformerVocals))
    }

    @Test func importsOnlyRequestedPackages() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.put("htdemucs.safetensors", in: fx.demucsCache)
        try fx.put("htdemucs_config.json", in: fx.demucsCache)
        try fx.put("htdemucs_6s.safetensors", in: fx.demucsCache)
        try fx.put("htdemucs.safetensors.verified.json", in: fx.demucsCache, "{}")
        try putSW(fx)
        try fx.put("download_checks.json", in: fx.roformerCache, "{\"vecchio\": 1}")

        try fx.store.ensureInstalled([.htdemucs])
        // Neither the other Demucs, nor files outside the catalog, nor the Roformers.
        #expect(fx.names("demucs") == ["htdemucs.safetensors", "htdemucs_config.json"])
        #expect(fx.names("roformer").isEmpty)
    }

    @Test func copiesMissingOnly() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.put("htdemucs.safetensors", in: fx.demucsCache)
        try fx.put("htdemucs_config.json", in: fx.demucsCache)
        try fx.store.ensureInstalled([.htdemucs])

        let weights = fx.destination.appending(path: "demucs/htdemucs.safetensors")
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: weights.path)
        try fx.store.ensureInstalled([.htdemucs])
        let date = try FileManager.default.attributesOfItem(atPath: weights.path)[.modificationDate] as? Date
        #expect(date == old)
    }

    @Test func writesMinimalDownloadChecks() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try putSW(fx)
        try fx.store.ensureInstalled([.roformerSW])

        let url = fx.destination.appending(path: "roformer/download_checks.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(json.keys) == ["vr_download_list", "mdx_download_list", "demucs_download_list",
                                   "mdx23c_download_list", "roformer_download_list"])
        let roformer = try #require(json["roformer_download_list"] as? [String: [String: String]])
        #expect(roformer == ["BS-Roformer-Viperx-1297": ["model_bs_roformer_ep_317_sdr_12.9755.ckpt": "model_bs_roformer_ep_317_sdr_12.9755.yaml"]])
        #expect((json["vr_download_list"] as? [String: Any])?.isEmpty == true)

        // One already present is not rewritten.
        try Data("{\"mio\": 1}".utf8).write(to: url)
        try fx.store.ensureInstalled([.roformerSW])
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"mio\": 1}")
    }

    @Test func installMovesVerifiedFileInPlace() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let store = fx.store
        let file = Self.catalog.package(.roformerSW).files[0]
        try FileManager.default.createDirectory(at: store.downloadsDirectory, withIntermediateDirectories: true)
        let temp = store.downloadsDirectory.appending(path: file.name)
        try Data("sw".utf8).write(to: temp)

        try store.install(file, from: temp)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(try String(contentsOf: store.roformerDirectory.appending(path: file.name), encoding: .utf8) == "sw")
    }

    @Test func installRejectsWrongHashAndDeletesTemp() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let store = fx.store
        let file = Self.catalog.package(.roformerSW).files[0]
        try FileManager.default.createDirectory(at: store.downloadsDirectory, withIntermediateDirectories: true)
        let temp = store.downloadsDirectory.appending(path: file.name)
        try Data("sW".utf8).write(to: temp)

        #expect(throws: ModelStoreError.checksumMismatch(file: file.name)) { try store.install(file, from: temp) }
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(!FileManager.default.fileExists(atPath: store.roformerDirectory.appending(path: file.name).path))
    }

    /// A downloaded config is normalized like an imported one.
    @Test func installNormalizesConfig() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let store = fx.store
        let file = Self.catalog.package(.htdemucs).files[1]
        try FileManager.default.createDirectory(at: store.downloadsDirectory, withIntermediateDirectories: true)
        let temp = store.downloadsDirectory.appending(path: file.name)
        try Data(Self.rawConfig.utf8).write(to: temp)

        try store.install(file, from: temp)
        let data = try Data(contentsOf: store.demucsDirectory.appending(path: file.name))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["kwargs"] as? [String: Any])?["segment"] as? String == "39/5")
    }

    @Test func removeDeletesOnlyThatPackage() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try putSW(fx)
        try fx.put("model_bs_roformer_ep_317_sdr_12.9755.ckpt", in: fx.roformerCache)
        try fx.put("model_bs_roformer_ep_317_sdr_12.9755.yaml", in: fx.roformerCache)
        try fx.store.ensureInstalled([.roformerVocals, .roformerSW])

        try fx.store.remove(.roformerSW)
        #expect(!fx.store.isInstalled(.roformerSW))
        #expect(fx.store.isInstalled(.roformerVocals))
        #expect(fx.names("roformer") == ["model_bs_roformer_ep_317_sdr_12.9755.ckpt",
                                         "model_bs_roformer_ep_317_sdr_12.9755.yaml", "download_checks.json"])
        // Removing a model that is not there is not an error.
        try fx.store.remove(.roformerSW)
    }

    /// `segment` as a dictionary makes the library fall back to 8.0 s windows.
    @Test func configSegmentIsNormalized() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try fx.put("htdemucs.safetensors", in: fx.demucsCache)
        try fx.put("htdemucs_config.json", in: fx.demucsCache)
        try fx.store.ensureInstalled([.htdemucs])

        let data = try Data(contentsOf: try fx.store.demucsWeights("htdemucs").config)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kwargs = try #require(json["kwargs"] as? [String: Any])
        #expect(kwargs["segment"] as? String == "39/5")
        #expect(kwargs["channels"] as? Int == 48)
        let perModel = try #require(json["per_model_kwargs"] as? [[String: Any]])
        #expect(perModel.first?["segment"] as? String == "39/5")
    }
}
