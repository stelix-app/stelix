// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Accelerate
import Foundation
import StelixCore
import Synchronization

// MARK: - Fake model

/// The early prototype's "separator", on the real 7.8 s window: the input goes all to Other, the other
/// stems are zeros. It serves to try the pipeline without MLX.
final class IdentityModel: SeparationModel {
    let sampleRate = 44_100.0
    let windowFrames = Int((7.8 * 44_100).rounded())   // 343 980
    let stems = Stem.live

    func separate(planarStereo: [Float]) throws -> [[Float]] {
        let silence = [Float](repeating: 0, count: planarStereo.count)
        return stems.map { $0 == .other ? planarStereo : silence }
    }
}

// MARK: - LiveEngine

/// Live: `.mutedWhenTapped` tap, input ring, ML thread that fills the stem timeline,
/// IOProc that plays the timeline with a fixed delay. All the control state lives on the `control`
/// queue; the IOProc touches only `LivePipeline.render` and its atomics.
final class LiveEngine: @unchecked Sendable {
    private let control = DispatchQueue(label: "io.github.stelix-app.stelix.engine.live", qos: .userInitiated)
    /// Loading the model (seconds) does not block commands: it runs here and returns to `control`.
    private let loader = DispatchQueue(label: "io.github.stelix-app.stelix.engine.model", qos: .userInitiated)
    private let emit: @Sendable (Event) -> Void
    private let loadModel: @Sendable (LiveLevel) throws -> SeparationModel

    // On the `control` queue.
    private var active = false
    private var level = LiveLevel.intermediate
    private var mix = StemMix.allOn(Stem.live)
    private var telemetry = false
    private var pipeline: LivePipeline?
    private var watcher: DeviceWatcher?
    private var monitor: DispatchSourceTimer?
    private var watchdog: SilenceWatchdog?
    private var watchdogFrame: Int64 = 0
    private var lastWritten: Int64 = 0
    private var lastFillEmit = -1.0
    private var waitingForAudio = false
    /// When the output has changed, until the signal returns: for the log only.
    private var deviceChangedAt: Double?
    private var lastStats = DispatchTime.now()
    private var underrunsBefore = 0   // of the pipelines already destroyed
    private var recovery = LiveRecovery()
    /// Counts the minutes without sound from when Live is turned on: at the end Live turns itself off.
    private var idle = LiveIdleTimer(startedAt: 0)
    private var lastBuildError: EngineFailure?
    private var model: SeparationModel?
    private var loadedModelName: String?
    /// The loaded model's pass on this Mac: from the warm-up, then the slowest p95 seen if Live fell behind.
    private var passSeconds: Double?
    /// The tempo of what plays, with the panel open; `nil` before macOS 27.
    private lazy var tempo: LiveTempo? = TempoAnalysis.isAvailable ? LiveTempo(control: control, emit: emit) : nil
    /// Times Live fell behind and was rebuilt with a longer delay, since the start or the level change.
    private var restretches = 0
    static let maxRestretches = 3
    /// Passes of a pipeline before their median says that the model does not fit.
    static let passesBeforeJudging = 6
    private var loading = false
    private var generation = 0          // grows at every load and every stop: cancels the old ones
    /// Copy of `generation` for the loading queue: an already superseded load does not even start.
    private let loadGeneration = Atomic<Int>(0)
    private var lastLevels = 0
    /// A delay measurement is in progress: a second request is ignored (it would reset the capture and
    /// give two `.measuredDelay`).
    private var measuring = false

    static let fadeSeconds = 0.040
    private static let monitorInterval = DispatchTimeInterval.milliseconds(50)
    private static let statsInterval = 0.25

    init(emit: @escaping @Sendable (Event) -> Void,
         loadModel: @escaping @Sendable (LiveLevel) throws -> SeparationModel = LiveEngine.defaultLoader) {
        self.emit = emit
        self.loadModel = loadModel
    }

    /// Copies the weights if missing, loads the level's model and warms it up.
    /// `STELIX_IDENTITY_MODEL=1` uses the identity (the input to Other), to try the pipeline without MLX.
    static let defaultLoader: @Sendable (LiveLevel) throws -> SeparationModel = { level in
        if ProcessInfo.processInfo.environment["STELIX_IDENTITY_MODEL"] == "1" { return IdentityModel() }
        let store = ModelStore()
        try store.ensureInstalled(ModelCatalog.models(for: level))
        // The previous model is already released: its buffers stay in MLX's cache until
        // it is emptied (Pro → Intermediate kept 11 GB instead of about 4.5).
        DemucsMLXModel.releaseCachedMemory()
        let model = try DemucsMLXModel(name: level.modelName, store: store)
        try model.warmUp()
        engineLog("live: MLX memory \(DemucsMLXModel.memorySummary)")
        return model
    }

    // MARK: Comandi

    func start(level: LiveLevel, mix: StemMix) {
        control.async { [self] in
            guard !active else {
                applyMix(mix)
                if level != self.level { changeLevel(level) }
                return
            }
            active = true
            self.level = level
            self.mix = mix
            watchdog = nil
            watchdogFrame = 0
            underrunsBefore = 0
            recovery = LiveRecovery()
            restretches = 0
            idle = LiveIdleTimer(startedAt: Self.now())
            emit(.live(.warming))
            watcher = DeviceWatcher { [weak self] in self?.control.async { self?.deviceChanged() } }
            startMonitor()
            prepareModelThenBuild()
        }
    }

    func setMix(_ mix: StemMix) {
        control.async { [self] in applyMix(mix) }
    }

    func setLevel(_ level: LiveLevel) {
        control.async { [self] in
            guard level != self.level else { return }
            guard active else { self.level = level; return }
            changeLevel(level)
        }
    }

    func setTelemetry(_ on: Bool) {
        control.async { [self] in telemetry = on }
    }

    /// For 6 s the IOProc copies channel 0 of the tap input and of the mixed output; then, outside
    /// the IOProc, cross-correlation gives the real delay, emitted as `.measuredDelay`.
    func measureDelay() {
        control.async { [self] in
            guard !measuring else {
                engineLog("live: measurement already in progress, request ignored")
                return
            }
            guard active, let pipeline, pipeline.isRunning else {
                emit(.failure(EngineFailure(.measureNotLive)))
                return
            }
            engineLog("live: delay measurement, \(Int(LivePipeline.captureSeconds)) s")
            measuring = true
            pipeline.beginCapture()
            awaitCapture(pipeline, deadline: Self.now() + LivePipeline.captureSeconds + 3)
        }
    }

    /// Until `deadline`: if the IOProc does not fill the capture (the output is not playing) the measurement ends there.
    private func awaitCapture(_ captured: LivePipeline, deadline: Double) {
        control.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard let pipeline, pipeline === captured else {
                measuring = false
                emit(.failure(EngineFailure(.measureOutputChanged)))
                return
            }
            guard pipeline.captureDone else {
                guard Self.now() < deadline else {
                    measuring = false
                    emit(.failure(EngineFailure(.measureNoSignal)))
                    return
                }
                awaitCapture(pipeline, deadline: deadline)
                return
            }
            let signals = pipeline.capturedSignals()
            let rate = pipeline.timing.deviceRate
            let expected = pipeline.timing.delaySeconds
            DispatchQueue.global(qos: .utility).async { [self] in
                let found = DelayEstimator.lag(reference: signals.input, delayed: signals.output, maxLag: Int(rate * (LiveSchedule.maxDelay + 1)))
                control.async { [self] in
                    measuring = false
                    guard let found else {
                        emit(.failure(EngineFailure(.measureNoSignal)))
                        return
                    }
                    let seconds = Double(found.lag) / rate
                    engineLog(String(format: "live: delay measured %.3f s (expected %.3f, correlation %.2f)", seconds, expected, found.score))
                    emit(.measuredDelay(seconds: seconds))
                }
            }
        }
    }

    /// 40 ms fade, then stop and destruction of IOProc, aggregate and tap; then `.stopped`.
    func stop() {
        control.async { [self] in
            guard active else {
                emit(.live(.stopped))
                return
            }
            shutdown(fade: true)
            emit(.live(.stopped))
        }
    }

    /// For process exit: like `stop`, but waits until everything is destroyed and emits nothing.
    func stopAndWait() {
        control.sync { [self] in
            if active { shutdown(fade: true) }
        }
    }

    // MARK: On the `control` queue

    private func applyMix(_ mix: StemMix) {
        self.mix = mix
        pipeline?.mixer.apply(mix)
    }

    /// 40 ms fade and stop; if the level uses another model, the old one is released and the
    /// new one loaded (`.warming`, meanwhile the original is heard); then the same path as start.
    ///
    /// With the same model (Base ↔ Intermediate) the new pipeline is born before the old one dies:
    /// the old tap keeps the Mac silent as long as the new one exists, so the original does not escape in
    /// the hundreds of ms between the destruction of one tap and the birth of the other. The old ML thread
    /// stops before the new one starts: the model never works on two threads together. The
    /// buffer fill remains, in silence, because the delay changes.
    private func changeLevel(_ level: LiveLevel) {
        let sameModel = model != nil && level.modelName == loadedModelName && !loading
        self.level = level
        restretches = 0
        if sameModel, let old = pipeline {
            emit(.live(.rebuilding))
            if old.isRunning {
                old.mixer.setMaster(0)
                Thread.sleep(forTimeInterval: Self.fadeSeconds + 0.015)
            }
            old.worker.stop()
            pipeline = nil
            bumpGeneration()
            buildOrRetry()
            old.tap.stop()
            old.tap.destroy()
            old.timeline.reset()
            underrunsBefore += old.underruns
            return
        }
        destroyPipeline(fade: true)
        emit(.live(level.modelName == loadedModelName ? .rebuilding : .warming))
        prepareModelThenBuild()
    }

    /// First the model (if it is not already the one in memory), then tap and pipeline: the original is heard
    /// until the model is ready.
    private func prepareModelThenBuild() {
        bumpGeneration()
        let generation = generation
        let level = level
        if model != nil, loadedModelName == level.modelName {
            buildOrRetry()
            return
        }
        model = nil              // the old one is released before loading the new one
        loadedModelName = nil
        passSeconds = nil
        loading = true
        let load = loadModel
        loader.async { [weak self] in
            // Several level changes in a row: the last wins, the others load nothing.
            guard let self, self.loadGeneration.load(ordering: .acquiring) == generation else { return }
            let began = DispatchTime.now().uptimeNanoseconds
            let result: Result<ModelBox, EngineFailure>
            do {
                result = .success(ModelBox(try load(level)))
            } catch {
                result = .failure(Self.loadFailure(error, level: level))
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
            control.async { self.modelLoaded(result, level: level, generation: generation, ms: ms) }
        }
    }

    private func modelLoaded(_ result: Result<ModelBox, EngineFailure>, level: LiveLevel, generation: Int, ms: Double) {
        // A stop or another level in the meantime: this model is no longer needed and is released here.
        guard active, generation == self.generation else { return }
        loading = false
        switch result {
        case .success(let box):
            model = box.model
            loadedModelName = level.modelName
            passSeconds = box.model.passSeconds
            engineLog("live: model \(level.modelName) ready in \(Int(ms)) ms, pass \(passSeconds.map { "\(Int($0 * 1000)) ms" } ?? "not measured")")
            buildOrRetry()
        case .failure(let failure):
            giveUp(failure)
        }
    }

    private func bumpGeneration() {
        generation += 1
        loadGeneration.store(generation, ordering: .releasing)
    }

    private static func loadFailure(_ error: Error, level: LiveLevel) -> EngineFailure {
        engineLog("live: loading \(level.modelName) failed: \(error)")
        return EngineFailure(error, fallback: EngineFailure(.modelLoad, detail: level.rawValue))
    }

    private func buildOrRetry() {
        do throws(EngineFailure) {
            try buildPipeline()
        } catch {
            // This Mac is too slow for the level: no retry would change that.
            if error.message == .modelTooSlow {
                giveUp(error)
                return
            }
            // Retry after 0.5 s and then after 2 s (`recovery` says so in `tick`), then give up.
            engineLog("live: pipeline creation failed: \(error.code)")
            lastBuildError = error
            if recovery.buildFailed(at: Self.now()) == .giveUp { giveUp(error) }
        }
    }

    private func buildPipeline() throws(EngineFailure) {
        guard let model else { throw EngineFailure(.modelNotReady) }
        // Before the tap: a level that does not fit does not silence the Mac even for a moment.
        guard let schedule = LiveSchedule.fitting(level: level, passSeconds: passSeconds) else {
            engineLog("live: pass \(Int((passSeconds ?? 0) * 1000)) ms, too slow for \(level.rawValue) even with "
                      + "\(LiveSchedule.maxDelay) s of delay")
            throw EngineFailure(.modelTooSlow, detail: level.rawValue)
        }
        if schedule.isStretched {
            engineLog(String(format: "live: pass %d ms on this Mac, %@ stretched: hop %.2f s, margin %.2f s, delay %.2f s",
                             Int((passSeconds ?? 0) * 1000), level.rawValue, schedule.hop, schedule.margin, schedule.delay))
        }
        let tap = try SystemTap(mute: .mutedWhenTapped)
        let timing = LiveTiming(level: level, schedule: schedule, deviceRate: tap.format.sampleRate)
        let pipeline = LivePipeline(tap: tap, timing: timing, model: model)
        pipeline.mixer.apply(mix)
        if watchdog == nil { watchdog = SilenceWatchdog(sampleRate: tap.format.sampleRate) }
        lastWritten = 0
        lastFillEmit = -1
        waitingForAudio = false
        lastLevels = 0           // the new worker counts chunks from 0
        do throws(EngineFailure) {
            pipeline.worker.start()
            try tap.start(render: pipeline.makeRender())
        } catch {
            pipeline.worker.stop()
            tap.destroy()
            throw error
        }
        self.pipeline = pipeline
        recovery.pipelineStarted(at: Self.now())
        let f = tap.format
        engineLog("live: \(LogPrivacy.mark(tap.outputName)) [\(LogPrivacy.mark(tap.outputUID))] \(Int(f.sampleRate)) Hz, \(tap.routeDescription)\(f.isBluetooth ? ", Bluetooth" : ""); \(level.rawValue), delay \(timing.delayFrames) frames")
    }

    /// Fade (if requested), `AudioDeviceStop`, then ML thread, IOProc, aggregate and tap.
    private func destroyPipeline(fade: Bool) {
        guard let pipeline else { return }
        tempo?.stop(tellApp: true)
        if fade, pipeline.isRunning {
            pipeline.mixer.setMaster(0)
            // 40 ms of ramp plus one device buffer.
            Thread.sleep(forTimeInterval: Self.fadeSeconds + 0.015)
        }
        pipeline.tap.stop()
        pipeline.worker.stop()
        pipeline.tap.destroy()
        pipeline.timeline.reset()
        underrunsBefore += pipeline.underruns
        self.pipeline = nil
    }

    private func shutdown(fade: Bool) {
        destroyPipeline(fade: fade)
        bumpGeneration()         // a queued load does not start, one in progress is discarded
        loading = false
        model = nil
        loadedModelName = nil
        passSeconds = nil
        monitor?.cancel()
        monitor = nil
        watcher?.invalidate()
        watcher = nil
        active = false
    }

    /// While the model loads there is nothing to rebuild: the pipeline will be born later,
    /// on the output of that moment.
    private func rebuild() {
        guard active, !loading else { return }
        emit(.live(.rebuilding))
        destroyPipeline(fade: true)
        buildOrRetry()
    }

    /// Live cannot restart: `.failure` with the reason, then tap and aggregate away (the audio returns to
    /// normal) and `.stopped`, which the ModeController reads as giving up.
    private func giveUp(_ failure: EngineFailure) {
        engineLog("live: giving up: \(failure.code)")
        emit(.failure(failure))
        shutdown(fade: true)
        emit(.live(.stopped))
    }

    /// Minutes without sound: the same path as `stop` (tap away, the audio returns to normal), the model
    /// and MLX's cache released, then `.stoppedForSilence`. The app goes back to Original, which shuts the engine down.
    private func stopForSilence() {
        engineLog("live: \(Int(LiveIdleTimer.limit)) s without sound, turning off")
        shutdown(fade: true)
        DemucsMLXModel.releaseCachedMemory()
        engineLog("live: MLX memory \(DemucsMLXModel.memorySummary)")
        emit(.live(.stoppedForSilence))
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// The model fell behind after the start: the GPU slowed down as it warmed up (a MacBook Air has no
    /// fan) or another app is using it. If the passes seen now fit a longer delay, Live is rebuilt with it,
    /// at most `maxRestretches` times; otherwise it gives up as before. The median, not the p95: with 20
    /// passes the p95 is the slowest one, and a single page-in would make the level look impossible.
    /// The stretched schedule leaves the pass 30% of room above it.
    private func restretch(_ pipeline: LivePipeline) -> Bool {
        let seen = max(pipeline.worker.modelTimes().median / 1000, passSeconds ?? 0)
        guard restretches < Self.maxRestretches, seen > 0,
              let schedule = LiveSchedule.fitting(level: level, passSeconds: seen),
              Int((schedule.delay * pipeline.timing.deviceRate).rounded()) > pipeline.timing.delayFrames
        else { return false }
        restretches += 1
        passSeconds = seen
        engineLog(String(format: "live: fell behind with passes of %d ms, rebuilding with %.2f s of delay",
                         Int(seen * 1000), schedule.delay))
        rebuild()
        return true
    }

    private func deviceChanged() {
        guard active else { return }
        // Creating tap and aggregate can trigger output notifications without anything changing:
        // rebuild only if device, rate or channels are really different.
        if let pipeline, pipeline.tap.signature == SystemTap.OutputSignature.current() { return }
        engineLog("live: output changed, rebuilding")
        idle.outputChanged(at: Self.now())
        watchdog?.noteDeviceChange(atFrame: watchdogFrame)
        deviceChangedAt = Self.now()
        rebuild()
    }

    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + Self.monitorInterval, repeating: Self.monitorInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        monitor = timer
    }

    /// 20 times per second: silence, fill, watchdog, levels, telemetry. Only the silence count runs
    /// while the model loads.
    private func tick() {
        guard active else { return }
        let outputIO = pipeline.map { CoreAudioProperty.isRunningSomewhere($0.tap.signature.device) }
        if idle.observe(at: Self.now(), outputRunning: outputIO ?? false, peak: pipeline?.takePeak() ?? 0) {
            stopForSilence()
            return
        }
        guard !loading else { return }
        // With the Mac silent the output does no IO and the tap does not call: wait for the music, it is not a stall.
        let outputRunning = outputIO ?? true
        switch recovery.observe(at: Self.now(), written: pipeline?.ring.writtenFrames ?? 0, outputRunning: outputRunning) {
        case .none: break
        case .rebuild:
            engineLog(pipeline == nil ? "live: new attempt" : "live: no callback, rebuilding")
            rebuild()
            return
        case .giveUp:
            giveUp(pipeline == nil
                   ? lastBuildError ?? EngineFailure(.outputSetup)
                   : EngineFailure(.noAudio))
            return
        }
        guard let pipeline else { return }
        let written = pipeline.ring.writtenFrames
        let delay = pipeline.timing.delayFrames

        // The model does not deliver or fails to start: with the tap silencing the Mac we would stay
        // mute with no reason. We give up, and the audio returns to normal.
        if pipeline.timing.modelIsStalled(written: written, available: pipeline.timeline.availableUpTo,
                                          playing: pipeline.isRunning) {
            if restretch(pipeline) { return }
            giveUp(EngineFailure(.modelTooSlow, detail: level.rawValue))
            return
        }

        // Passes longer than their time: the ML thread skips bands and Live crackles, but the
        // timeline keeps moving, so the stall above never fires. The median, not the p95: one slow pass
        // (a page-in, another app for a moment) is covered by the provisional band.
        let passes = pipeline.worker.modelTimes()
        if pipeline.isRunning, passes.count >= Self.passesBeforeJudging,
           passes.median / 1000 > pipeline.timing.modelBudget {
            if restretch(pipeline) { return }
            giveUp(EngineFailure(.modelTooSlow, detail: level.rawValue))
            return
        }

        if !pipeline.isRunning {
            // It plays when the ring has the delay and the timeline already covers one hop beyond the
            // playback point: the model's first pass can last longer than the margin (warm-up).
            let playFrame = written - Int64(delay)
            if playFrame >= 0, pipeline.timeline.availableUpTo >= playFrame + Int64(pipeline.timing.hopFrames) {
                pipeline.startPlaying()
                emit(.live(.running))
            } else if !outputRunning, written == lastWritten {
                // Mac silent: no frames until something plays. It is said once.
                if !waitingForAudio {
                    waitingForAudio = true
                    emit(.live(.waitingForAudio))
                }
            } else {
                if waitingForAudio {
                    waitingForAudio = false
                    lastFillEmit = -1    // the next fill is sent even if it is still 0
                }
                let fraction = min(1, (Double(written) / Double(max(1, delay)) * 20).rounded(.down) / 20)
                if fraction > lastFillEmit {
                    lastFillEmit = fraction
                    emit(.live(.filling(fraction: fraction)))
                }
            }
        }

        let delta = written - lastWritten
        lastWritten = written
        if delta > 0, var dog = watchdog {
            // The watchdog counts in the rate it was born with; after a rate change it is converted.
            let frames = Int((Double(delta) * dog.sampleRate / pipeline.timing.deviceRate).rounded())
            let signal = pipeline.takeSignal()
            if signal, let changed = deviceChangedAt {
                // Diagnostics of the double rebuild toward the speakers.
                engineLog(String(format: "live: first signal %.2f s after the output change", Self.now() - changed))
                deviceChangedAt = nil
            }
            let action = dog.observe(atFrame: watchdogFrame, frames: frames, allZero: !signal)
            watchdogFrame += Int64(frames)
            watchdog = dog
            switch action {
            case .none: break
            case .permissionSuspected:
                engineLog("live: only zeros since the start, suspected permission")
                emit(.permissionSuspected)
            case .rebuild:
                let device = pipeline.tap.signature.device
                engineLog("live: zeros after the output change, rebuilding (output IO: "
                          + "\(CoreAudioProperty.isRunningSomewhere(device)), still the default: "
                          + "\(CoreAudioProperty.defaultOutputDevice() == device))")
                rebuild()
                return
            }
        }

        tempo?.tick(pipeline: pipeline, active: telemetry && pipeline.isRunning, now: Self.now())

        if pipeline.isRunning, let levels = pipeline.worker.levels(after: lastLevels) {
            lastLevels = levels.sequence
            emit(.levels(Dictionary(uniqueKeysWithValues: zip(pipeline.model.stems, levels.rms))))
        }

        let now = DispatchTime.now()
        if telemetry, Double(now.uptimeNanoseconds - lastStats.uptimeNanoseconds) / 1e9 >= Self.statsInterval {
            lastStats = now
            let model = pipeline.worker.modelTimes()
            emit(.liveStats(LiveStats(
                delaySeconds: pipeline.delaySeconds,
                modelMs: model.median,
                load: model.p95 / 1000 / pipeline.timing.modelBudget,
                underruns: underrunsBefore + pipeline.underruns,
                outputIsBluetooth: pipeline.tap.format.isBluetooth)))
        }
    }
}

// MARK: - Pipeline

/// Everything that lives as long as a tap: recreated at every rebuild, with the new rate.
final class LivePipeline: @unchecked Sendable {
    let tap: SystemTap
    let timing: LiveTiming
    let ring: SPSCRingBuffer
    let timeline: StemTimeline
    let mixer: StemMixer
    let worker: SeparationWorker
    let model: SeparationModel
    private let state: RenderState

    /// The ring holds 12 s: the model windows are 7.8 s. The timeline holds 10 s, above the
    /// longest delay plus one hop (`LiveSchedule.maxDelay`: 5 s, with a hop of at most 2.5 s).
    init(tap: SystemTap, timing: LiveTiming, model: SeparationModel) {
        let rate = tap.format.sampleRate
        self.tap = tap
        self.timing = timing
        self.model = model
        ring = SPSCRingBuffer(channels: tap.format.inputChannels, capacityFrames: Int(rate * 12))
        timeline = StemTimeline(stems: model.stems.count, channels: 2, capacityFrames: Int(rate * 10))
        mixer = StemMixer(stems: model.stems, sampleRate: rate)
        state = RenderState(stems: model.stems.count, maxFrames: 4096, captureFrames: Int(rate * Self.captureSeconds))
        worker = SeparationWorker(ring: ring, timeline: timeline, timing: timing, model: model)
    }

    /// Long enough to find the longest delay with 4 s of overlap.
    static let captureSeconds = LiveSchedule.maxDelay + 4

    var isRunning: Bool { state.playing.load(ordering: .acquiring) }

    /// The IOProc starts copying input and output into the measurement buffers.
    func beginCapture() {
        state.captured.store(0, ordering: .relaxed)
        state.capturing.store(true, ordering: .releasing)
    }

    var captureDone: Bool { state.captured.load(ordering: .acquiring) >= state.captureFrames }

    /// Copy of the measurement buffers, to be called when `captureDone`.
    func capturedSignals() -> (input: [Float], output: [Float]) {
        let n = state.captured.load(ordering: .acquiring)
        return (Array(UnsafeBufferPointer(start: state.captureIn, count: n)),
                Array(UnsafeBufferPointer(start: state.captureOut, count: n)))
    }
    var underruns: Int { state.underruns.load(ordering: .relaxed) }

    /// Real delay: most recent input frame minus frame being played, measured in the IOProc.
    var delaySeconds: Double {
        Double(state.inputEnd.load(ordering: .relaxed) - state.playEnd.load(ordering: .relaxed)) / timing.deviceRate
    }

    /// The timeline is full for the delay: the master comes in with the 40 ms fade and from here underruns count.
    func startPlaying() {
        state.playing.store(true, ordering: .releasing)
        mixer.setMaster(1)
    }

    /// `true` if at least one non-zero sample has arrived since the last call.
    func takeSignal() -> Bool {
        state.signal.exchange(false, ordering: .relaxed)
    }

    /// The largest absolute input sample since the last call (0 if no frames arrived).
    func takePeak() -> Float {
        Float(bitPattern: state.peakBits.exchange(0, ordering: .relaxed))
    }

    /// The IOProc block. No locks, allocations, logs.
    func makeRender() -> SystemTap.Render {
        let ring = ring, timeline = timeline, mixer = mixer, state = state
        let inChannels = tap.format.inputChannels
        let outChannels = tap.format.outputChannels
        let delay = Int64(timing.delayFrames)
        return { input, output, frames in
            let start = ring.writtenFrames
            ring.write(input, frames: frames)
            var peak: Float = 0
            vDSP_maxmgv(input, 1, &peak, vDSP_Length(frames * inChannels))
            if peak > 0 {
                state.signal.store(true, ordering: .relaxed)
                // Non-negative floats keep their order as bit patterns: an atomic max on the integers.
                state.peakBits.max(peak.bitPattern, ordering: .relaxed)
            }
            let end = start + Int64(frames)
            state.inputEnd.store(end, ordering: .relaxed)
            state.playEnd.store(end - delay, ordering: .relaxed)
            guard let output else { return }

            let counting = state.playing.load(ordering: .relaxed)
            var done = 0
            while done < frames {
                let n = min(frames - done, state.maxFrames)
                let playFrame = start + Int64(done) - delay
                // The model is late and the timeline is about to end: fade before the gap, not after.
                if counting { mixer.guardAgainstGap(framesAhead: timeline.availableUpTo - playFrame, frames: n) }
                let got = timeline.read(at: playFrame, frames: n, into: state.stems)
                if counting && got < n { state.underruns.add(1, ordering: .relaxed) }
                mixer.render(stemFrames: state.stems, frames: n, channels: 2,
                             out: output + done * outChannels, outChannels: outChannels)
                done += n
            }

            // Delay measurement: channel 0 of input and output, in preallocated buffers.
            if state.capturing.load(ordering: .acquiring) {
                let have = state.captured.load(ordering: .relaxed)
                let n = min(frames, state.captureFrames - have)
                for f in 0..<n {
                    state.captureIn[have + f] = input[f * inChannels]
                    state.captureOut[have + f] = output[f * outChannels]
                }
                if have + n >= state.captureFrames { state.capturing.store(false, ordering: .relaxed) }
                state.captured.store(have + n, ordering: .releasing)
            }
        }
    }
}

/// IOProc buffers and counters, preallocated.
private final class RenderState: @unchecked Sendable {
    let maxFrames: Int
    let stems: UnsafeMutablePointer<Float>
    let playing = Atomic<Bool>(false)
    let signal = Atomic<Bool>(false)
    /// Bit pattern of the input peak (a non-negative Float), reset by `takePeak`.
    let peakBits = Atomic<UInt32>(0)
    let underruns = Atomic<Int>(0)
    let inputEnd = Atomic<Int64>(0)
    let playEnd = Atomic<Int64>(0)
    let captureFrames: Int
    let captureIn: UnsafeMutablePointer<Float>
    let captureOut: UnsafeMutablePointer<Float>
    let capturing = Atomic<Bool>(false)
    let captured = Atomic<Int>(0)

    init(stems count: Int, maxFrames: Int, captureFrames: Int) {
        self.maxFrames = maxFrames
        stems = .allocate(capacity: count * maxFrames * 2)
        stems.initialize(repeating: 0, count: count * maxFrames * 2)
        self.captureFrames = captureFrames
        captureIn = .allocate(capacity: captureFrames)
        captureIn.initialize(repeating: 0, count: captureFrames)
        captureOut = .allocate(capacity: captureFrames)
        captureOut.initialize(repeating: 0, count: captureFrames)
    }

    deinit {
        stems.deallocate()
        captureIn.deallocate()
        captureOut.deallocate()
    }
}

// MARK: - Thread ML

/// At every edge (`lookahead + hop`, then from `hop` to `hop`) it calls `StreamingSeparator.step`, which
/// passes the model the last 7.8 s and returns the band `[edge - lookahead - hop, edge - lookahead)`;
/// the band goes into the timeline at the same frame indices. The pass must finish within the margin.
final class SeparationWorker: @unchecked Sendable {
    private let ring: SPSCRingBuffer
    private let timeline: StemTimeline
    private let timing: LiveTiming
    private let separator: StreamingSeparator
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private let times = Mutex<[Double]>([])
    private let latestLevels = Mutex<(sequence: Int, rms: [Float])>((0, []))
    private static let timesKept = 20

    init(ring: SPSCRingBuffer, timeline: StemTimeline, timing: LiveTiming, model: SeparationModel) {
        self.ring = ring
        self.timeline = timeline
        self.timing = timing
        separator = StreamingSeparator(model: model, timing: timing, deviceRate: timing.deviceRate,
                                       resampler: AVResampler())
    }

    func start() {
        let thread = Thread { [self] in run(); finished.signal() }
        thread.name = "io.github.stelix-app.stelix.engine.ml"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the thread and waits for it to exit. Idempotent.
    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .relaxed)
        finished.wait()
        thread = nil
    }

    /// Median and p95 of the last 20 passes, in ms, and how many passes they come from.
    func modelTimes() -> (median: Double, p95: Double, count: Int) {
        times.withLock { values in
            guard !values.isEmpty else { return (0, 0, 0) }
            let sorted = values.sorted()
            return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.count)
        }
    }

    /// RMS per stem of the last chunk, if it is newer than `sequence`.
    func levels(after sequence: Int) -> (sequence: Int, rms: [Float])? {
        latestLevels.withLock { $0.sequence > sequence && !$0.rms.isEmpty ? $0 : nil }
    }

    private func run() {
        let rate = timing.deviceRate
        let hop = Int64(timing.hopFrames)
        var nextEdge = StreamingSeparator.firstEdge(timing)
        var lastError: String?

        while !stopFlag.load(ordering: .relaxed) {
            let written = ring.writtenFrames
            guard written >= nextEdge else {
                Thread.sleep(forTimeInterval: max(0.001, min(0.02, Double(nextEdge - written) / rate)))
                continue
            }
            // Fell behind by more than a hop: jump to the last past edge. The skipped bands
            // underrun anyway, and the crossfade restarts from zero.
            if written - nextEdge >= hop { nextEdge += (written - nextEdge) / hop * hop }
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                if let separated = try separator.step(ring: ring, edge: nextEdge) {
                    let chunk = gated(separated)
                    chunk.data.withUnsafeBufferPointer {
                        timeline.write(startFrame: chunk.startFrame, frames: chunk.frames, data: $0.baseAddress!)
                    }
                    let rms = Self.rms(chunk)
                    latestLevels.withLock { $0 = ($0.sequence + 1, rms) }
                }
                lastError = nil
            } catch {
                let text = "\(error)"
                if text != lastError { engineLog("live: model pass failed: \(text)") }
                lastError = text
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
            times.withLock { values in
                values.append(ms)
                if values.count > Self.timesKept { values.removeFirst(values.count - Self.timesKept) }
            }
            nextEdge += hop
        }
    }

    /// Where the input is digital silence the stems are silence (`SilenceGate`): no model residue after a
    /// stop. The input around the chunk comes from the ring; if it cannot be read the chunk stays as it is.
    private func gated(_ chunk: StemChunk) -> StemChunk {
        let block = max(1, Int(SilenceGate.blockSeconds * timing.deviceRate))
        let range = SilenceGate.inputRange(startFrame: chunk.startFrame, frames: chunk.frames, blockFrames: block)
        let from = max(0, range.lowerBound)
        let to = min(ring.writtenFrames, range.upperBound)
        guard to > from else { return chunk }
        var input = [Float](repeating: 0, count: Int(to - from) * ring.channels)
        let read = input.withUnsafeMutableBufferPointer { ring.copy(from: from, frames: Int(to - from), into: $0.baseAddress!) }
        guard read else { return chunk }
        var data = chunk.data
        let stems = chunk.frames > 0 ? data.count / (chunk.frames * 2) : 0
        SilenceGate.apply(to: &data, stems: stems, startFrame: chunk.startFrame, frames: chunk.frames,
                          input: input, inputStart: from, channels: ring.channels, blockFrames: block)
        return StemChunk(startFrame: chunk.startFrame, frames: chunk.frames, settledFrames: chunk.settledFrames, data: data)
    }

    /// RMS of each stem on both channels.
    private static func rms(_ chunk: StemChunk) -> [Float] {
        let perStem = chunk.frames * 2
        guard perStem > 0 else { return [] }
        return (0..<(chunk.data.count / perStem)).map { s in
            var sum: Float = 0
            for i in (s * perStem)..<((s + 1) * perStem) { sum += chunk.data[i] * chunk.data[i] }
            return (sum / Float(perStem)).squareRoot()
        }
    }
}

/// Passes the model from the loading queue to `control`. Used by one thread at a time.
private final class ModelBox: @unchecked Sendable {
    let model: SeparationModel
    init(_ model: SeparationModel) { self.model = model }
}

/// The engine's log: one line on stderr, which the app copies into the system log. The names of the
/// user's files never go here (`LogPrivacy.describe(file:)`), and the names of devices only inside
/// `LogPrivacy.mark`: the app hides them, a terminal shows them. With Stelix dead nobody reads stderr: the
/// write fails and the line is lost. `write(_:)` would raise an Objective-C exception there and abort the
/// engine before it empties the temporary folder (Task 10.10).
func engineLog(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}
