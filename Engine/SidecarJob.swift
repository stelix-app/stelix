// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import StelixCore

/// Studio Intermediate and Pro: a whole file to 6 stems in the Python sidecar (`Contents/Resources/sidecar`).
///
/// 1. The file is loaded at 44.1 kHz with `AudioFileLoader`, as in Base (video, 5.1, 20 minute
///    cap), and written as Float32 in a working folder in `$TMPDIR`: the sidecar always reads
///    a stereo 44.1 kHz WAV, the same mix on which it computes "Other" in Pro.
/// 2. `python3 -B -I stelix_sidecar.py --level … --input … --output … --models …`, with a pipe on stdin
///    that stays open: if the engine dies, the sidecar exits by itself.
/// 3. Progress lines become `.job` (from 5 to 90%), an error line becomes the error of the
///    job.
/// 4. At the end the engine reads the 6 stems for the peaks and moves them into the track's temporary folder:
///    first all on temporary names, then the renames onto the real names.
///
/// The working folder is always deleted, even when the job is cancelled or fails.
struct SidecarJob {
    static let failed = EngineFailure(.separationFailed)
    static let writeFailed = EngineFailure(.stemsUnwritable)

    let level: StudioLevel
    let emit: @Sendable (Event) -> Void
    let isCancelled: () -> Bool
    /// Receives the process before launch, so `.cancelJob` can stop it.
    let attach: (SidecarProcess) -> Void

    /// `Contents/Resources/sidecar` next to `Contents/MacOS/StelixEngine`. Only in Debug builds
    /// `STELIX_SIDECAR_DIR` replaces it, for tests outside the bundle (for example `sidecar/dist`):
    /// in Release an environment variable cannot make Stelix launch an arbitrary Python.
    static var directory: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["STELIX_SIDECAR_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/sidecar")
    }

    func run(url: URL, into folder: URL) throws -> StemsResult {
        emit(.job(progress: 0, step: .readingFile))
        let audio = try AudioFileLoader.load(url, sampleRate: 44_100)
        let duration = Double(audio.frames) / 44_100
        engineLog(String(format: "studio: %@, %.1f s, level %@", LogPrivacy.describe(file: url), duration, level.rawValue))
        try checkCancelled()

        let store = ModelStore()
        try store.ensureInstalled(ModelCatalog.models(for: level))

        let fm = FileManager.default
        // A killed engine (kill -9) does not delete its working folder: the next job removes it.
        // There is one job at a time and only one engine.
        let temp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix(StudioScratch.sidecarWorkPrefix) {
            try? fm.removeItem(at: temp.appending(path: name))
        }
        let work = temp.appending(path: StudioScratch.sidecarWorkPrefix + UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work.appending(path: "stems"), withIntermediateDirectories: true)
        } catch {
            throw Self.writeFailed
        }
        let input = work.appending(path: "input.wav")
        try StemFiles.writeWAV(audio.planarStereo, frames: audio.frames, sampleRate: 44_100, to: input)
        try checkCancelled()

        let files = try separate(input: input, output: work.appending(path: "stems"), models: store.roformerDirectory)
        try checkCancelled()

        emit(.job(progress: 0.9, step: .writingStems))
        var waveforms: [Stem: [Float]] = [:]
        for stem in Stem.allCases {
            guard let path = files[stem] else { throw Self.failed }
            let stemAudio = try AudioFileLoader.load(URL(fileURLWithPath: path), sampleRate: 44_100)
            waveforms[stem] = Peaks.compute(planarStereo: stemAudio.planarStereo, frames: stemAudio.frames)
        }
        try checkCancelled()

        let placed = try place(files, into: folder)
        return StemsResult(folder: folder.path, files: placed.mapValues(\.path), duration: duration, waveforms: waveforms)
    }

    private func checkCancelled() throws(EngineFailure) {
        if isCancelled() { throw SidecarProcess.cancelled }
    }

    /// The sidecar on `input`: the 6 stems in `output`, or the error it reported.
    private func separate(input: URL, output: URL, models: URL) throws(EngineFailure) -> [Stem: String] {
        let dir = Self.directory
        let process = SidecarProcess(
            executable: dir.appending(path: "python/bin/python3"),
            // -B: no .pyc written into the signed bundle (the bytecode is already there); -I ignores the environment.
            arguments: ["-B", "-I", dir.appending(path: "stelix_sidecar.py").path, "--level", level.rawValue,
                        "--input", input.path, "--output", output.path, "--models", models.path])
        attach(process)

        emit(.job(progress: 0.05, step: .preparingModel))
        let began = Date()
        var lastSent = 0.05
        var lastStep = JobStep.preparingModel
        var done: [Stem: String]?
        var reported: EngineFailure?
        let exit = try process.run { message in
            switch message {
            case .progress(let fraction, let step):
                let value = 0.05 + 0.85 * min(1, max(0, fraction))
                // A new step is always sent, even if the bar moved only a little.
                guard value - lastSent >= 0.01 || step != lastStep else { return }
                lastSent = value
                lastStep = step
                emit(.job(progress: value, step: step))
            case .done(let files):
                done = files
            case .error(let failure):
                reported = failure
            }
        }
        engineLog(String(format: "studio: sidecar %@ finished in %.1f s (exit %d%@)", level.rawValue,
                         Date().timeIntervalSince(began), exit.status, exit.signaled ? ", signal" : ""))
        if process.wasCancelled || isCancelled() { throw SidecarProcess.cancelled }
        if let reported { throw reported }
        guard let done, !exit.signaled, exit.status == 0,
              Stem.allCases.allSatisfy({ done[$0].map(FileManager.default.fileExists(atPath:)) ?? false })
        else { throw Self.failed }
        return done
    }

    /// The sidecar's stems into the Studio folder with `Stem.fileName`: first all on
    /// `.<name>.partial` (rename, or copy if the working folder is on another volume), then the
    /// renames onto the real names. An error or a cancellation leaves the previous stems as they were.
    private func place(_ files: [Stem: String], into folder: URL) throws(EngineFailure) -> [Stem: URL] {
        let fm = FileManager.default
        var partials: [(stem: Stem, partial: URL, final: URL)] = []
        func discard() { for item in partials { try? fm.removeItem(at: item.partial) } }

        for stem in Stem.allCases {
            guard let source = files[stem] else { throw Self.failed }
            let final = folder.appending(path: stem.fileName)
            let partial = folder.appending(path: ".\(stem.fileName)\(StemFiles.partialSuffix)")
            try? fm.removeItem(at: partial)
            partials.append((stem, partial, final))
            if rename(source, partial.path) != 0 {
                do { try fm.copyItem(at: URL(fileURLWithPath: source), to: partial) } catch {
                    discard()
                    throw Self.writeFailed
                }
            }
        }
        if isCancelled() {
            discard()
            throw SidecarProcess.cancelled
        }
        do throws(EngineFailure) {
            try StemFiles.commit(partials.map { ($0.partial, $0.final) })
        } catch {
            throw Self.writeFailed
        }
        return Dictionary(uniqueKeysWithValues: partials.map { ($0.stem, $0.final) })
    }
}
