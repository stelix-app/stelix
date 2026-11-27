// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import CoreAudio
import Foundation
import StelixCore
import Synchronization

/// The Studio player: `AVAudioEngine` with one `AVAudioPlayerNode` per stem, connected by `StudioGraph`
/// (all on the main mixer at 0 semitones; the stems but the drums through the time pitch otherwise).
/// They are started together at the same `AVAudioTime`; pause and seek stop all the nodes and reschedule
/// them from the right frame, so they stay in sync. Every load starts at 0 semitones: the app sends the
/// transpose after the stems (`StudioSession`).
///
/// - `.setMix` → `node.volume = effectiveGain`;
/// - `.player(position:duration:playing:)` at 10 Hz while it plays, and at every state change;
/// - `.levels` at 20 Hz with telemetry on, from the `installTap` on each node's output
///   (before the volume, like the Live levels).
final class StudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.stelix-app.stelix.engine.player", qos: .userInitiated)
    private let emit: @Sendable (Event) -> Void

    // On the `queue` queue.
    private var engine: AVAudioEngine?
    private var graph: StudioGraph?
    private var nodes: [Stem: AVAudioPlayerNode] = [:]
    private var files: [Stem: AVAudioFile] = [:]
    private var lengthFrames: AVAudioFramePosition = 0
    private var sampleRate = 44_100.0
    /// Frame from which the last scheduling started; the position is this plus the node's time.
    private var startFrame: AVAudioFramePosition = 0
    /// The last position read from a playing node, updated at every tick. On an output change the
    /// system stops the engine and `lastRenderTime` becomes nil: we were here.
    private var lastPosition: AVAudioFramePosition = 0
    private var playing = false
    private var mix = StemMix.allOn(Stem.studio)
    private var telemetry = false
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var configObserver: NSObjectProtocol?
    /// Listens to macOS's default output device. AVAudioEngine follows it by itself and does not
    /// always send `AVAudioEngineConfigurationChange`: without this the player would continue on the
    /// new output, jumping forward by the duration of the switch (and, if the headphones are unplugged,
    /// would play from the speakers).
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private let rms = Mutex<[Stem: Float]>([:])
    /// Play, pause and seek fade the whole player in and out instead of cutting the waves mid-way: a cut
    /// is a click, like a jack pulled out of an audio interface (Gabriele, 13/11). The mix is not touched.
    static let fadeSeconds = 0.025
    private static let fadeSteps = 10
    /// Changes at every fade: the steps of a fade-in still to come stop when a pause arrives. On `queue`.
    private var fadeGeneration = 0

    init(emit: @escaping @Sendable (Event) -> Void) {
        self.emit = emit
    }

    // MARK: Comandi

    /// Loads the stems, stopped at `position` (the start for freshly separated ones).
    func load(_ result: StemsResult, at position: Double = 0) {
        queue.async { [self] in
            teardown()
            do throws(EngineFailure) {
                try build(result)
                if position > 0 { seek(to: position) }
                emitState()
            } catch {
                teardown()
                emit(.failure(error))
            }
        }
    }

    func handle(_ command: PlayerCommand) {
        queue.async { [self] in
            guard engine != nil else {
                emit(.failure(EngineFailure(.noStems)))
                return
            }
            switch command {
            case .play: play()
            case .pause: pause()
            case .seek(let seconds): seek(to: seconds)
            }
            emitState()
        }
    }

    func setMix(_ mix: StemMix) {
        queue.async { [self] in
            self.mix = mix
            applyMix()
        }
    }

    func setTelemetry(_ on: Bool) {
        queue.async { [self] in telemetry = on }
    }

    /// Between two values only the pitch changes, playing. Crossing 0 rewires the graph: a pause with its
    /// fade, then on from the same point if it was playing. Without stems: nothing.
    func setTranspose(_ value: Transpose) {
        queue.async { [self] in
            guard let graph, let engine else { return }
            guard value.isOff != graph.transpose.isOff else {
                graph.setTranspose(value)
                return
            }
            let wasPlaying = playing
            let here = position
            fadeOut()
            for node in nodes.values { node.stop() }
            playing = false
            engine.stop()
            graph.setTranspose(value)
            installTaps()
            engine.prepare()
            do { try engine.start() } catch {
                emit(.failure(EngineFailure(.outputUnplayable)))
            }
            startFrame = here
            if wasPlaying { play() }
            emitState()
        }
    }

    func stopAndWait() {
        queue.sync {
            fadeOut()
            teardown()
        }
    }

    // MARK: On the `queue` queue

    private func build(_ result: StemsResult) throws(EngineFailure) {
        let engine = AVAudioEngine()
        var files: [Stem: AVAudioFile] = [:]
        for stem in Stem.studio {
            guard let path = result.files[stem] else { continue }
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
                throw EngineFailure(.stemUnreadable, detail: stem.rawValue)
            }
            files[stem] = file
        }
        let graph = try StudioGraph(engine: engine, files: files)
        let length = graph.lengthFrames
        sampleRate = graph.sampleRate
        self.graph = graph
        self.nodes = graph.nodes
        installTaps()
        engine.prepare()
        do { try engine.start() } catch {
            throw EngineFailure(.outputUnplayable)
        }
        self.engine = engine
        self.files = files
        lengthFrames = length
        startFrame = 0
        playing = false
        applyMix()

        // Output change: AVAudioEngine stops by itself. Restart paused where it was.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.configurationChanged() }
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputDeviceChanged() }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            deviceListener = listener
        }
        startTimer()
        engineLog(String(format: "player: %d stems, %.1f s at %.0f Hz", nodes.count, Double(length) / sampleRate, sampleRate))
    }

    /// The levels of each stem, before the volume, like the Live ones. Again after a rewiring.
    private func installTaps() {
        for (stem, node) in nodes {
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                let value = Self.rms(buffer)
                self?.rms.withLock { $0[stem] = value }
            }
        }
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let deviceListener {
            var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        }
        deviceListener = nil
        for node in nodes.values {
            node.removeTap(onBus: 0)
            node.stop()
        }
        engine?.stop()
        engine = nil
        graph = nil
        nodes = [:]
        files = [:]
        playing = false
        startFrame = 0
        lastPosition = 0
        rms.withLock { $0 = [:] }
    }

    private func applyMix() {
        for (stem, node) in nodes { node.volume = mix.effectiveGain(stem) }
    }

    /// From the clock node (the drums, which start as late as the time pitch delays the rest), minus what is
    /// still in the limiter.
    private var position: AVAudioFramePosition {
        guard playing else { return startFrame }
        guard let graph, let nodeTime = graph.clockNode.lastRenderTime,
              let playerTime = graph.clockNode.playerTime(forNodeTime: nodeTime) else { return max(startFrame, lastPosition) }
        let heard = playerTime.sampleTime - AVAudioFramePosition(graph.latencyFrames)
        return min(lengthFrames, startFrame + max(0, heard))
    }

    private func play() {
        guard !playing, let engine else { return }
        if startFrame >= lengthFrames { startFrame = 0 }
        if !engine.isRunning {
            do { try engine.start() } catch {
                emit(.failure(EngineFailure(.outputUnplayable)))
                return
            }
        }
        guard let graph else { return }
        // Also empties the time pitch: nothing from before a pause or a seek comes out.
        graph.schedule(from: startFrame)
        // All at the same instant (the drums as late as the time pitch delays the rest), 50 ms in the
        // future: enough to reach all the nodes.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        fadeIn(after: 0.05 + Double(graph.drumsDelayFrames + graph.latencyFrames) / sampleRate)
        graph.play(at: start)
        lastPosition = startFrame
        playing = true
    }

    private func pause() {
        guard playing else { return }
        fadeOut()
        let here = position
        for node in nodes.values { node.stop() }
        playing = false
        startFrame = here
    }

    private func seek(to seconds: Double) {
        let target = AVAudioFramePosition((max(0, seconds) * sampleRate).rounded())
        let wasPlaying = playing
        if playing {
            fadeOut()
            for node in nodes.values { node.stop() }
            playing = false
        }
        startFrame = min(target, lengthFrames)
        // A seek all the way to the end during play stops there, like at the end of the track: play()
        // ripartirebbe da 0.
        if wasPlaying, startFrame < lengthFrames { play() }
    }

    /// The default device has changed: pause where it was (the last position read by the tick, if
    /// the engine has already stopped). The next play restarts on the new output.
    private func outputDeviceChanged() {
        guard engine != nil else { return }
        engineLog("player: output device changed")
        guard playing else { return }
        // At most 50 ms earlier: better to hear a moment again than to lose what was played into the void
        // during the switch.
        let here = max(startFrame, min(lastPosition, position))
        for node in nodes.values { node.stop() }
        playing = false
        startFrame = here
        emitState()
    }

    private func configurationChanged() {
        guard let engine else { return }
        engineLog("player: output changed")
        pause()
        // The new output may have another rate or other channels: the mixer reconnects with the device
        // format, as AVAudioEngine does by itself at the first start.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        }
        engine.prepare()
        do { try engine.start() } catch {
            emit(.failure(EngineFailure(.outputUnplayable)))
        }
        emitState()
    }

    /// Blocks the queue for `fadeSeconds`, while the nodes keep playing. Nothing if they are not playing.
    private func fadeOut() {
        guard playing, let mixer = engine?.mainMixerNode else { return }
        fadeGeneration += 1
        let from = mixer.outputVolume
        for step in 1...Self.fadeSteps {
            mixer.outputVolume = from * Float(Self.fadeSteps - step) / Float(Self.fadeSteps)
            Thread.sleep(forTimeInterval: Self.fadeSeconds / Double(Self.fadeSteps))
        }
    }

    /// From silence to full volume, starting `delay` from now (when the nodes start), without blocking.
    private func fadeIn(after delay: Double) {
        guard let mixer = engine?.mainMixerNode else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        mixer.outputVolume = 0
        for step in 1...Self.fadeSteps {
            let at = DispatchTime.now() + delay + Self.fadeSeconds * Double(step) / Double(Self.fadeSteps)
            queue.asyncAfter(deadline: at) { [weak self] in
                guard let self, self.fadeGeneration == generation, let mixer = self.engine?.mainMixerNode else { return }
                mixer.outputVolume = Float(step) / Float(Self.fadeSteps)
            }
        }
    }

    private func emitState() {
        emit(.player(position: Double(position) / sampleRate, duration: Double(lengthFrames) / sampleRate, playing: playing))
    }

    /// 20 Hz: levels every turn (with telemetry), position every other turn.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard playing else { return }
        ticks += 1
        let here = position
        lastPosition = here
        if here >= lengthFrames {
            // End of the track: stopped, and the next play restarts from the beginning.
            for node in nodes.values { node.stop() }
            playing = false
            startFrame = lengthFrames
            emitState()
            return
        }
        if telemetry {
            let levels = rms.withLock { $0 }
            if !levels.isEmpty { emit(.levels(levels)) }
        }
        if ticks % 2 == 0 { emitState() }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        for c in 0..<channels {
            for f in 0..<frames { sum += data[c][f] * data[c][f] }
        }
        return (sum / Float(frames * channels)).squareRoot()
    }
}
