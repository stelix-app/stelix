// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// The models Stelix knows how to use. The `rawValue` is also the `detail` of a `missingWeights` error.
public enum ModelID: String, Codable, Sendable, CaseIterable {
    case htdemucs
    case htdemucsFT = "htdemucs_ft"
    case htdemucs6s = "htdemucs_6s"
    case roformerSW = "bs_roformer_sw"
    case roformerVocals = "bs_roformer_ep317"
}

/// The subfolder of `Models/`: Demucs for the engine, the Roformers for the sidecar.
public enum ModelFolder: String, Sendable {
    case demucs, roformer
}

/// A model file, with its source and the fingerprint it must have.
public struct ModelFile: Sendable, Equatable {
    public let name: String
    public let folder: ModelFolder
    public let url: URL
    /// Lowercase hexadecimal SHA-256 of the file as the source serves it.
    public let sha256: String
    public let size: Int64

    public init(name: String, folder: ModelFolder, url: URL, sha256: String, size: Int64) {
        self.name = name
        self.folder = folder
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

/// The license status of the weights. The app writes the text.
public enum ModelLicense: String, Sendable {
    /// Demucs: the author writes "The license of the weights is not clear" (htdemucs_6s "likely
    /// CC-NC-BY"); the mirror's card says MIT, but what the author says prevails.
    case demucsUnclear
    /// Known author, no license declared (ep_317, viperx).
    case undeclared
    /// Provenance not verified, no license declared (SW).
    case undeclaredUnverified
}

/// A model as the user sees it: one or more files, downloaded and removed together.
public struct ModelPackage: Sendable, Equatable {
    public let id: ModelID
    public let files: [ModelFile]
    public let author: String
    /// Host plus path, shown in the notice (for example "huggingface.co/ssmall256/demucs-mlx").
    public let source: String
    public let license: ModelLicense

    public var size: Int64 { files.reduce(0) { $0 + $1.size } }

    public init(id: ModelID, files: [ModelFile], author: String, source: String, license: ModelLicense) {
        self.id = id
        self.files = files
        self.author = author
        self.source = source
        self.license = license
    }
}

/// The models, where they are downloaded from and what fingerprint they have. The fingerprints of the large files come from the
/// files in `~/.cache` on the development Mac, those of the small ones from the downloaded files, identical byte for
/// byte (verified on 2026-11-08). htdemucs reconverted from Meta's checkpoint with the demucs-mlx
/// converter gives the same SHA-256 (verified on 2026-11-09).
public struct ModelCatalog: Sendable {
    public let packages: [ModelPackage]

    public init(packages: [ModelPackage]) {
        self.packages = packages
    }

    /// The package for `id`. A catalog without that model is a programming error.
    public func package(_ id: ModelID) -> ModelPackage {
        guard let package = packages.first(where: { $0.id == id }) else {
            preconditionFailure("\(id.rawValue) is not in the catalog")
        }
        return package
    }

    public func file(sha256: String) -> ModelFile? {
        packages.lazy.flatMap(\.files).first { $0.sha256 == sha256 }
    }

    public func package(containing fileName: String) -> ModelPackage? {
        packages.first { $0.files.contains { $0.name == fileName } }
    }

    public static func models(for level: LiveLevel) -> [ModelID] {
        switch level {
        case .base, .intermediate: [.htdemucs]
        case .pro: [.htdemucsFT]
        }
    }

    /// In Pro ep_317 makes the voice and SW the rest: if both are missing, ep_317 is named first.
    public static func models(for level: StudioLevel) -> [ModelID] {
        switch level {
        case .base: [.htdemucs6s]
        case .intermediate: [.roformerSW]
        case .pro: [.roformerVocals, .roformerSW]
        }
    }

    public static let shipped: ModelCatalog = {
        let hf = "https://huggingface.co/ssmall256/demucs-mlx/resolve/35ecb1a906ec420b1a28069db575ad070d35860e/"
        let configs = "https://github.com/nomadkaraoke/python-audio-separator/releases/download/model-configs/"
        let uvr = "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/"
        func file(_ base: String, _ name: String, _ folder: ModelFolder, _ sha256: String, _ size: Int64) -> ModelFile {
            ModelFile(name: name, folder: folder, url: URL(string: base + name)!, sha256: sha256, size: size)
        }
        func demucs(_ id: ModelID, _ weights: (String, Int64), _ config: (String, Int64)) -> ModelPackage {
            ModelPackage(
                id: id,
                files: [file(hf, "\(id.rawValue).safetensors", .demucs, weights.0, weights.1),
                        file(hf, "\(id.rawValue)_config.json", .demucs, config.0, config.1)],
                author: "Alexandre Défossez (Meta); MLX conversion by ssmall256",
                source: "huggingface.co/ssmall256/demucs-mlx",
                license: .demucsUnclear)
        }
        return ModelCatalog(packages: [
            demucs(.htdemucs,
                   ("339d267a7a6983a11eedbdc00413c602a65e9b9103f695fb5c2b2a481cd9d297", 168_005_865),
                   ("23657b19db14771aecf366ceedbf846c1386836c10043c97f4569acf05526b78", 4_215)),
            demucs(.htdemucsFT,
                   ("53f03b1ad4b4d211025a35da65460ba61a17547adf9c0544cad0ebcc8d7bbabb", 672_024_519),
                   ("6708535a698d4d4dd285a6f0a80d9d3c228fdd6514e53bdf1ddbc2ee9b0fa872", 10_253)),
            demucs(.htdemucs6s,
                   ("d298f7f746bf53c21baad44fb08e88807ef47feb551dd22f1601a546c85b8e02", 109_726_583),
                   ("d5e18c0209be583027d6eb5ec3013a02cd7ef55bc3096e644d8d3577d92e9bd0", 4_302)),
            ModelPackage(
                id: .roformerSW,
                files: [file(configs, "BS-Roformer-SW.ckpt", .roformer,
                             "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e", 699_412_152),
                        file(configs, "BS-Roformer-SW.yaml", .roformer,
                             "b558996f1e25eb48798bd6502505a5de94c4f966d6edfb1a0420f06cc40b501a", 4_653)],
                author: "unknown (hosted by python-audio-separator)",
                source: "github.com/nomadkaraoke/python-audio-separator",
                license: .undeclaredUnverified),
            ModelPackage(
                id: .roformerVocals,
                files: [file(uvr, "model_bs_roformer_ep_317_sdr_12.9755.ckpt", .roformer,
                             "5b84f37e8d444c8cb30c79d77f613a41c05868ff9c9ac6c7049c00aefae115aa", 639_331_213),
                        file(configs, "model_bs_roformer_ep_317_sdr_12.9755.yaml", .roformer,
                             "2bfdd16c656bd9519aba757cc4f8834b7ede675eb1e00ec4772d74ae1c41af7f", 2_273)],
                author: "viperx (UVR)",
                source: "github.com/TRvlvr/model_repo",
                license: .undeclared),
        ])
    }()
}
