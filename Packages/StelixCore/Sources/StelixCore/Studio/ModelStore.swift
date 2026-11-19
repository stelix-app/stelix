// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

public enum ModelStoreError: Error, Equatable, Sendable {
    /// At least one file of the model is still missing.
    case missing(ModelID)
    /// The file does not have the catalog's fingerprint: it was deleted.
    case checksumMismatch(file: String)
    /// "Add Model…" with a file that is not in the catalog.
    case notInCatalog
    /// Cannot write to `Models/`.
    case write
    /// The `Models/` volume does not have the bytes needed (what is missing plus 10%).
    case notEnoughSpace(needed: Int64)
}

/// The model weights in `~/Library/Application Support/Stelix/Models`: Demucs in `demucs/`, the
/// sidecar's Roformers in `roformer/`. Never in git, never in the bundle.
///
/// A file counts as installed only after the fingerprint check against the catalog: the app
/// downloads it or it arrives with "Add Model…", but it always goes through a temporary name and gets the real name
/// only if the fingerprint matches. No network here: if a file is missing, it says which model is missing.
///
/// No `sources` by default: a model removed in Settings stays removed. Importing from `~/.cache`
/// (the developer's Mac) brought a removed model back on its own the next time it was needed.
public struct ModelStore: Sendable {
    public let destination: URL
    public let sources: [URL]
    public let catalog: ModelCatalog

    public init(destination: URL = .applicationSupportDirectory.appending(path: "Stelix/Models"),
                sources: [URL] = [],
                catalog: ModelCatalog = .shipped) {
        self.destination = destination
        self.sources = sources
        self.catalog = catalog
    }

    public var demucsDirectory: URL { destination.appending(path: "demucs") }
    public var roformerDirectory: URL { destination.appending(path: "roformer") }
    /// Where the app downloads files before the check. It is on the same volume as `Models/`, so
    /// installing is a move.
    public var downloadsDirectory: URL { destination.appending(path: ".downloads") }

    public func directory(_ folder: ModelFolder) -> URL {
        switch folder {
        case .demucs: demucsDirectory
        case .roformer: roformerDirectory
        }
    }

    func target(_ file: ModelFile) -> URL { directory(file.folder).appending(path: file.name) }

    /// All the model's files are in place. The fingerprint is not recomputed: they got there
    /// only after the check.
    public func isInstalled(_ id: ModelID) -> Bool {
        catalog.package(id).files.allSatisfy { FileManager.default.fileExists(atPath: target($0).path) }
    }

    /// The files of the models `ids` that are not in place, in the order of `ids`, without repetitions.
    public func missingFiles(_ ids: [ModelID]) -> [ModelFile] {
        var seen = Set<String>()
        return ids.flatMap { catalog.package($0).files }.filter {
            seen.insert($0.name).inserted && !FileManager.default.fileExists(atPath: target($0).path)
        }
    }

    /// How much there is to download for the models `ids` ("Pro needs 639 MB more").
    public func missingBytes(_ ids: [ModelID]) -> Int64 {
        missingFiles(ids).reduce(0) { $0 + $1.size }
    }

    /// Imports from `sources` the files the models `ids` are missing, if the fingerprint matches the
    /// catalog; a file with the wrong fingerprint is ignored. Then throws `.missing` for the first
    /// model, in the order of `ids`, that still lacks a file.
    /// `FileManager.copyItem` does a clonefile on APFS, so it takes no extra space.
    public func ensureInstalled(_ ids: [ModelID]) throws {
        let fm = FileManager.default
        for id in ids {
            for file in catalog.package(id).files where !fm.fileExists(atPath: target(file).path) {
                for source in sources {
                    let from = source.appending(path: file.name)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    if try importFile(file, from: from) { break }
                }
            }
        }
        if ids.contains(where: { catalog.package($0).files.contains { $0.folder == .roformer } }) {
            try writeDownloadChecksIfMissing()
        }
        if let missing = ids.first(where: { !isInstalled($0) }) {
            throw ModelStoreError.missing(missing)
        }
    }

    /// Copies `from` to a temporary name in `.downloads`, then installs it. False if the fingerprint
    /// does not match (the temporary file is already deleted).
    private func importFile(_ file: ModelFile, from: URL) throws -> Bool {
        let fm = FileManager.default
        let temporary = downloadsDirectory.appending(path: "\(file.name).import")
        do {
            try fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: from, to: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw ModelStoreError.write
        }
        do {
            try install(file, from: temporary)
            return true
        } catch ModelStoreError.checksumMismatch {
            return false
        }
    }

    /// Checks the fingerprint of `temporary` and moves it into place. The temporary file always
    /// disappears, even when the fingerprint does not match. Demucs configs are rewritten after the
    /// check, with `segment` as the string "n/d": the library reads only numbers or "39/5" strings, and a fraction object makes it fall back to 8.0 s windows (p95 162 → 201 ms).
    public func install(_ file: ModelFile, from temporary: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporary) }
        let digest: String
        do {
            digest = try FileDigest.sha256(of: temporary)
        } catch {
            throw ModelStoreError.write
        }
        guard digest == file.sha256 else { throw ModelStoreError.checksumMismatch(file: file.name) }

        let target = target(file)
        let partial = directory(file.folder).appending(path: ".\(file.name).partial")
        do {
            try fm.createDirectory(at: directory(file.folder), withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            if file.name.hasSuffix("_config.json") {
                try Self.normalizedConfig(Data(contentsOf: temporary)).write(to: partial)
            } else {
                try fm.moveItem(at: temporary, to: partial)
            }
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: target)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw ModelStoreError.write
        }
    }

    /// Removes the model's files. A file that is not there is not an error.
    public func remove(_ id: ModelID) throws {
        let fm = FileManager.default
        for file in catalog.package(id).files where fm.fileExists(atPath: target(file).path) {
            do {
                try fm.removeItem(at: target(file))
            } catch {
                throw ModelStoreError.write
            }
        }
    }

    /// `<name>.safetensors` and `<name>_config.json` in `demucs/`.
    public func demucsWeights(_ name: String) throws -> (weights: URL, config: URL) {
        let weights = demucsDirectory.appending(path: "\(name).safetensors")
        let config = demucsDirectory.appending(path: "\(name)_config.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: weights.path), fm.fileExists(atPath: config.path) else {
            throw ModelID(rawValue: name).map(ModelStoreError.missing) ?? ModelStoreError.notInCatalog
        }
        return (weights, config)
    }

    /// A checkpoint (or its yaml) in `roformer/`.
    public func roformerCheckpoint(_ file: String) throws -> URL {
        let url = roformerDirectory.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw catalog.package(containing: file).map { ModelStoreError.missing($0.id) } ?? ModelStoreError.notInCatalog
        }
        return url
    }

    /// The list of UVR models that mlx-audio-separator reads to find ep_317. If missing, the
    /// sidecar would download it from UVR's `main` branch, which changes over time: it is written here, minimal.
    private func writeDownloadChecksIfMissing() throws {
        let url = roformerDirectory.appending(path: "download_checks.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let checks: [String: Any] = [
            "vr_download_list": [String: Any](),
            "mdx_download_list": [String: Any](),
            "demucs_download_list": [String: Any](),
            "mdx23c_download_list": [String: Any](),
            "roformer_download_list": [
                "BS-Roformer-Viperx-1297": [
                    "model_bs_roformer_ep_317_sdr_12.9755.ckpt": "model_bs_roformer_ep_317_sdr_12.9755.yaml",
                ],
            ],
        ]
        do {
            try FileManager.default.createDirectory(at: roformerDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            throw ModelStoreError.write
        }
    }

    /// `segment` da `{"__type__": "fraction", "numerator": 39, "denominator": 5}` a `"39/5"`, in
    /// `kwargs` and in every `per_model_kwargs`. A config that cannot be read stays as it is.
    static func normalizedConfig(_ data: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        func fix(_ kwargs: [String: Any]) -> [String: Any] {
            var kwargs = kwargs
            if let s = kwargs["segment"] as? [String: Any], let n = s["numerator"] as? Int, let d = s["denominator"] as? Int {
                kwargs["segment"] = "\(n)/\(d)"
            }
            return kwargs
        }
        if let kwargs = json["kwargs"] as? [String: Any] { json["kwargs"] = fix(kwargs) }
        if let list = json["per_model_kwargs"] as? [[String: Any]] { json["per_model_kwargs"] = list.map(fix) }
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? data
    }
}
