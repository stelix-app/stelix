// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import DemucsMLX
import Foundation
import StelixCore
import Synchronization

/// Studio Base: a whole file to 6 stems with htdemucs_6s, inside the engine.
///
/// 1. The file is loaded at 44.1 kHz (`AudioFileLoader`). The stems go in the track's temporary
///    folder (`StudioScratch.folder(forSource:)`): a recording keeps its own, a file already
///    separated finds its own, the others get a new one.
/// 2. The library's offline pipeline separates in 7.8 s windows with 0.25 overlap.
/// 3. The 6 WAVs (Float32 stereo 44.1 kHz) go into the folder with `Stem.fileName`, written first on
///    temporary names and renamed all together (`StemFiles`).
/// 4. `.job(progress:step:)` during the work, then `.stemsReady` with 600 peaks per stem.
///
/// `.cancelJob` stops the library between one window and the next (or the writing between one file and the next),
/// deletes the temporaries and emits `.failure(code: "cancelled")`: the previous stems stay as they were.
///
/// Intermediate and Pro go through the Python sidecar (`SidecarJob`), with the same queue, the same state and
/// the same events; `.cancelJob` there sends SIGTERM to the sidecar, then SIGKILL after 1 s.
final class OfflineSeparator: @unchecked Sendable {
    static let modelName = "htdemucs_6s"

    private let queue = DispatchQueue(label: "io.github.stelix-app.stelix.engine.studio", qos: .userInitiated)
    private let emit: @Sendable (Event) -> Void
    private let scratch: StudioScratch
    private let finished: @Sendable (StemsResult) -> Void
    private let keys: KeyScans
    private let state = Mutex<JobState>(JobState())
    /// Only on the `queue` queue.
    private var model: DemucsMLXModel?

    private struct JobState {
        var running = false
        var token: DemucsCancelToken?
        var cancelled = false
        /// The sidecar of the Intermediate or Pro job in progress.
        var sidecar: SidecarProcess?
        /// The beats analysis of the job: a cancellation stops it too.
        var tempo: FileTempo?
    }

    /// `finished` receives the ready stems (the player loads them) before `.stemsReady`.
    init(scratch: StudioScratch, keys: KeyScans, emit: @escaping @Sendable (Event) -> Void,
         finished: @escaping @Sendable (StemsResult) -> Void) {
        self.scratch = scratch
        self.keys = keys
        self.emit = emit
        self.finished = finished
    }

    func separate(path: String, level: StudioLevel) {
        let busy = state.withLock { state -> Bool in
            if state.running { return true }
            state = JobState(running: true, token: DemucsCancelToken(), cancelled: false)
            return false
        }
        guard !busy else {
            emit(.failure(EngineFailure(.alreadySeparating)))
            return
        }
        queue.async { [self] in
            let began = Date()
            let url = URL(fileURLWithPath: path)
            // The beats of the source (the mix, not the drum stem: piani/ricerca-bpm.md), alongside.
            let tempo = FileTempo(url: url)
            state.withLock { $0.tempo = tempo }
            do {
                // The folders no longer needed are deleted by the scratch, even after an error.
                let folder = try scratch.folder(forSource: path)
                // The key over the clip, alongside too; the stems never wait for it.
                keys.jobStarted(path: path, folder: folder.path)
                var result: StemsResult
                if level == .base {
                    result = try run(url: url, into: folder)
                    engineLog(String(format: "studio: 6 stems in %.1f s, MLX memory %@", Date().timeIntervalSince(began),
                                     DemucsMLXModel.memorySummary))
                } else {
                    result = try sidecarJob(level: level).run(url: url, into: folder)
                    engineLog(String(format: "studio: 6 stems %@ in %.1f s", level.rawValue, Date().timeIntervalSince(began)))
                }
                // Usually already done: a few seconds of analysis against tens of separation.
                let analysis = tempo.wait()
                result.beats = analysis.beats
                state.withLock { $0 = JobState() }
                finished(result)
                emit(.stemsReady(result))
                keys.stemsReady(folder: result.folder)
            } catch {
                tempo.cancel()
                keys.jobEnded(path: path)
                let cancelled = state.withLock { state -> Bool in
                    defer { state = JobState() }
                    return state.cancelled
                }
                let failure = cancelled
                    ? EngineFailure(.separationCancelled)
                    : EngineFailure(error, fallback: EngineFailure(.separationFailed))
                engineLog("studio: \(failure.code) (\(LogPrivacy.describe(error: error)))")
                emit(.failure(failure))
            }
        }
    }

    /// A job is in progress (even if it is being cancelled).
    var isBusy: Bool { state.withLock { $0.running } }

    /// Valid only if a job is in progress. `true` if there was one.
    @discardableResult
    func cancel() -> Bool {
        let job = state.withLock { state -> (running: Bool, tempo: FileTempo?) in
            guard state.running else { return (false, nil) }
            state.cancelled = true
            state.token?.cancel()
            state.sidecar?.terminate()
            return (true, state.tempo)
        }
        // Past its last check a job still ends with its stems (a Cancel at 99%): they keep the beats that
        // arrive within the grace, and do not wait for them beyond it.
        job.tempo?.cancel(after: FileTempo.cancelGrace)
        return job.running
    }

    /// Engine exit: the job is stopped and we wait for the queue to free up.
    func stopAndWait() {
        cancel()
        // Past its last check a job still ends with its stems, which reach the app (Task 10.10): without waiting
        // for the beats, or SIGKILL would come first.
        state.withLock { $0.tempo }?.cancel()
        queue.sync {}
    }

    // MARK: On the `queue` queue

    private func sidecarJob(level: StudioLevel) -> SidecarJob {
        SidecarJob(level: level, emit: emit,
                   isCancelled: { [weak self] in self?.state.withLock { $0.cancelled } ?? true },
                   attach: { [weak self] process in
                       // If the cancellation arrived first, terminate() prevents the launch.
                       let cancelled = self?.state.withLock { state -> Bool in
                           state.sidecar = process
                           return state.cancelled
                       } ?? true
                       if cancelled { process.terminate() }
                   })
    }

    private func checkCancelled() throws(EngineFailure) {
        if state.withLock({ $0.cancelled }) { throw EngineFailure(.separationCancelled) }
    }

    private func run(url: URL, into folder: URL) throws -> StemsResult {
        emit(.job(progress: 0, step: .readingFile))
        let audio = try AudioFileLoader.load(url, sampleRate: 44_100)
        let duration = Double(audio.frames) / 44_100
        engineLog(String(format: "studio: %@, %.1f s", LogPrivacy.describe(file: url), duration))
        try checkCancelled()

        let model = try loadModel()
        try checkCancelled()
        guard let token = state.withLock({ $0.token }) else { throw EngineFailure(.separationCancelled) }

        // Separation goes from 5 to 90%; the library's progress arrives on main, in dense steps.
        emit(.job(progress: 0.05, step: .separating))
        let lastSent = Mutex(0.05)
        let emit = emit
        let stems = try model.separateFile(planarStereo: audio.planarStereo, cancel: token) { fraction in
            let value = 0.05 + 0.85 * min(1, max(0, fraction))
            let send = lastSent.withLock { last -> Bool in
                guard value - last >= 0.01 else { return false }
                last = value
                return true
            }
            if send { emit(.job(progress: value, step: .separating)) }
        }
        try checkCancelled()

        emit(.job(progress: 0.9, step: .writingStems))
        let written = try StemFiles.write(Array(zip(model.stems, stems)), frames: audio.frames, into: folder) {
            state.withLock { $0.cancelled }
        }
        var files: [Stem: String] = [:]
        var waveforms: [Stem: [Float]] = [:]
        for (index, stem) in model.stems.enumerated() {
            files[stem] = written[stem]?.path
            waveforms[stem] = Peaks.compute(planarStereo: stems[index], frames: audio.frames)
        }
        return StemsResult(folder: folder.path, files: files, duration: duration, waveforms: waveforms)
    }

    /// The model stays in memory between one job and the next: the Studio engine exits anyway
    /// when going back to Original.
    private func loadModel() throws -> DemucsMLXModel {
        if let model { return model }
        emit(.job(progress: 0.02, step: .preparingModel))
        let began = Date()
        let store = ModelStore()
        try store.ensureInstalled(ModelCatalog.models(for: StudioLevel.base))
        DemucsMLXModel.releaseCachedMemory()
        let model = try DemucsMLXModel(name: Self.modelName, store: store)
        engineLog(String(format: "studio: %@ ready in %.0f ms", Self.modelName, Date().timeIntervalSince(began) * 1000))
        self.model = model
        return model
    }
}
