// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import DemucsMLX
import Foundation
import MLX
import StelixCore

/// Demucs MLX on a 7.8 s window at 44.1 kHz (the library reads the config's `segment` as a number or a "n/d" string).
/// - "htdemucs": the 4 Live stems.
/// - "htdemucs_ft": 4 specialists, one stem each. The library loads them as a bag with one-hot weights
///   and in one `separate` makes the 4 passes, taking from each one its own stem.
/// - "htdemucs_6s": the 6 Studio stems.
///
/// Used from one thread at a time: the loading queue creates it, then only the ML thread uses it.
final class DemucsMLXModel: SeparationModel, @unchecked Sendable {
    let name: String
    let sampleRate = 44_100.0
    let windowFrames = Int((7.8 * 44_100).rounded())   // 343 980
    let stems: [Stem]
    /// This Mac's pass, measured by `warmUp`: `LiveSchedule` stretches the Live level if it does not fit.
    private(set) var passSeconds: Double?
    private let separator: DemucsSeparator

    init(name: String, store: ModelStore) throws {
        Self.locateMetallib
        self.name = name
        // First check that the files are there: if they are missing, the loader would download them from Hugging Face.
        let files = try store.demucsWeights(name)
        separator = try DemucsSeparator(modelName: name, modelDirectory: files.weights.deletingLastPathComponent())
        stems = name == "htdemucs_6s" ? Stem.studio : Stem.live
        guard separator.sampleRate == 44_100, separator.audioChannels == 2,
              stems.allSatisfy({ separator.sources.contains($0.rawValue) })
        else {
            throw EngineFailure(.modelUnexpected, detail: name)
        }
    }

    func separate(planarStereo: [Float]) throws -> [[Float]] {
        let audio = try DemucsAudio(channelMajor: planarStereo, channels: 2, sampleRate: 44_100)
        let result = try separator.separate(audio: audio)
        return try stems.map { stem in
            guard let samples = result.stems[stem.rawValue]?.channelMajorSamples else {
                throw EngineFailure(.modelMissingStem, detail: stem.rawValue)
            }
            return samples
        }
    }

    /// Studio: a whole file with the library's offline pipeline (7.8 s windows, 0.25
    /// overlap with triangular weights, cancellation checked between one window and the next). It blocks the
    /// caller, which must not be main: progress and completion arrive on the main queue.
    func separateFile(planarStereo: [Float], cancel: DemucsCancelToken,
                      progress: @escaping @Sendable (Double) -> Void) throws -> [[Float]] {
        precondition(!Thread.isMainThread, "separateFile waits on the main queue")
        let audio = try DemucsAudio(channelMajor: planarStereo, channels: 2, sampleRate: 44_100)
        let box = SeparationBox()
        let done = DispatchSemaphore(value: 0)
        separator.separate(audio: audio, cancelToken: cancel, interpolateProgress: true,
                           progress: { progress(Double($0.fraction)) },
                           completion: { result in
                               box.result = result
                               done.signal()
                           })
        done.wait()
        switch box.result {
        case .success(let result):
            return try stems.map { stem in
                guard let samples = result.stems[stem.rawValue]?.channelMajorSamples else {
                    throw EngineFailure(.modelMissingStem, detail: stem.rawValue)
                }
                return samples
            }
        case .failure(let error):
            if case DemucsError.cancelled = error { throw EngineFailure(.separationCancelled) }
            throw error
        case nil:
            throw EngineFailure(.separationIncomplete)
        }
    }

    /// MLX looks for `mlx-swift_Cmlx.bundle` next to the `mainBundle`, which for an executable inside
    /// `Stelix.app/Contents/MacOS` is the app: the bundle copied by build.sh next to StelixEngine would not
    /// find it ("Failed to load the default metallib", fatal). The path is set by hand.
    private static let locateMetallib: Void = {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let metallib = executable.deletingLastPathComponent()
            .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        if FileManager.default.fileExists(atPath: metallib.path) {
            GPU.metallib = metallib
        } else {
            engineLog("live: missing \(metallib.path)")
        }
    }()

    /// Returns to the system the free buffers MLX keeps in cache. Metallib first: any
    /// call to MLX without `GPU.metallib` set is fatal.
    static func releaseCachedMemory() {
        locateMetallib
        Memory.cacheLimit = cacheLimitBytes
        Memory.clearCache()
    }

    /// Without a cap MLX keeps the buffers of every pass in cache: 4.2 GB with htdemucs, 10.3 GB
    /// with htdemucs_ft (measured), against 165 and 662 MB of active memory.
    /// `STELIX_MLX_CACHE_LIMIT_MB` changes it, for measurements.
    static let cacheLimitBytes: Int = {
        if let mb = ProcessInfo.processInfo.environment["STELIX_MLX_CACHE_LIMIT_MB"].flatMap(Int.init) { return mb << 20 }
        return 1 << 30
    }()

    /// "active 3120 MB, cache 410 MB, peak 3900 MB"
    static var memorySummary: String {
        let mb = { (bytes: Int) in bytes / 1_048_576 }
        return "active \(mb(Memory.activeMemory)) MB, cache \(mb(Memory.cacheMemory)) MB, peak \(mb(Memory.peakMemory)) MB"
    }

    /// Three dry passes: the first call compiles the Metal kernels (0.2-0.9 s, up to 5.5 s
    /// at the very first launch). The faster of the other two is this Mac's pass: the cost of a pass
    /// does not depend on the audio, only on the window.
    func warmUp() throws {
        let silence = [Float](repeating: 0, count: 2 * windowFrames)
        _ = try separate(planarStereo: silence)
        var fastest = Double.infinity
        for _ in 0..<2 {
            let began = DispatchTime.now().uptimeNanoseconds
            _ = try separate(planarStereo: silence)
            fastest = min(fastest, Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9)
        }
        passSeconds = fastest
    }
}

private final class SeparationBox: @unchecked Sendable {
    var result: Result<DemucsSeparationResult, Error>?
}
