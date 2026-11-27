// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import Foundation
import Observation
import StelixCore

/// The Live state for the view: level and mix chosen (persisted), phase, statistics and levels
/// from the engine. It never touches the audio: commands go through `ModeController.send`.
@MainActor @Observable final class LiveViewModel {
    /// At most 30 `setMix` per second; the last change always goes out.
    static let mixSendsPerSecond = 30.0
    static let levelKey = "live.level"
    static let mixKey = "live.mix"
    static let audioPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    /// The delay measurement with cross-correlation (⌥ on "Behind by", a debug feature).
    enum Measurement: Equatable {
        case measuring
        case done(seconds: Double)
        case failed(EngineFailure)
    }

    var level: LiveLevel {
        didSet {
            guard level != oldValue else { return }
            defaults.set(level.rawValue, forKey: Self.levelKey)
            // A level without its model, or the Live waiting for one: the Live restarts, so
            // ModeController checks the models before an engine runs (by design:
            // the Live stops, the audio goes back to normal, the banner asks).
            if let controller, controller.selected == .live, modelsMissing(level) || Self.waitsForModel(controller.phase) {
                controller.select(.live)
            } else {
                controller?.send(.setLiveLevel(level))
            }
        }
    }

    /// True when `level` lacks a model. Set by the app from `ModelLibrary`.
    @ObservationIgnored var modelsMissing: (LiveLevel) -> Bool = { _ in false }

    private static func waitsForModel(_ phase: ModePhase) -> Bool {
        if case .failed(let failure) = phase { return failure.message == .missingWeights }
        return false
    }

    var mix: StemMix {
        didSet {
            guard mix != oldValue else { return }
            if let data = try? JSONEncoder().encode(mix) { defaults.set(data, forKey: Self.mixKey) }
            scheduleMixSend()
        }
    }

    /// `nil` until the current engine has said anything.
    private(set) var phase: LivePhase?
    /// They arrive only while the panel is open (telemetry).
    private(set) var stats: LiveStats?
    /// RMS per stem, from the last separated chunk.
    private(set) var levels: [Stem: Float] = [:]
    private(set) var permissionSuspected = false
    private(set) var measurement: Measurement?
    /// The tempo of what plays, from the engine (macOS 27, panel open); `nil` on silence.
    private(set) var tempo: Double?
    /// The key of what plays, from the engine (macOS 27, panel open); `nil` on silence.
    private(set) var key: MusicalKey?
    /// Back to 0 with every new engine: leaving the Live and coming back starts at 0.
    private(set) var transpose: Transpose = .off

    @ObservationIgnored weak var controller: ModeController?
    @ObservationIgnored private let defaults: UserDefaults
    /// Once real sound has come in, only zeros are a silent app, not a missing permission.
    @ObservationIgnored private let capturePermission: CapturePermissionMemory
    @ObservationIgnored private var throttle = SendThrottle(interval: 1 / LiveViewModel.mixSendsPerSecond)
    /// The switches from before a solo, to put back when the stem is held again. Not saved across launches.
    @ObservationIgnored private var soloMemory = SoloMemory()
    @ObservationIgnored private var panelOpen = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        capturePermission = CapturePermissionMemory(defaults: defaults)
        level = LiveLevel.initial(stored: defaults.string(forKey: Self.levelKey))
        mix = Self.storedMix(defaults) ?? .allOn(Stem.live)
    }

    // MARK: - View commands

    func apply(_ preset: Preset) {
        soloMemory.forget()
        mix = mix.applying(preset)
    }

    func setEnabled(_ stem: Stem, _ on: Bool) {
        soloMemory.forget()
        mix.controls[stem]?.enabled = on
    }

    /// Holding a stem's icon: that stem alone, or back to the switches from before its solo.
    func hold(_ stem: Stem) {
        mix = soloMemory.hold(stem, in: mix)
    }

    func setVolume(_ stem: Stem, _ volume: Float) {
        mix.controls[stem]?.volume = min(max(volume, 0), 1)
    }

    func raiseTranspose() { setTranspose(transpose.raised()) }
    func lowerTranspose() { setTranspose(transpose.lowered()) }

    /// Every click goes out at once: they are few, and each one changes the sound.
    func setTranspose(_ value: Transpose) {
        guard value != transpose else { return }
        transpose = value
        controller?.send(.setTranspose(semitones: value.semitones))
    }

    func selectLevel(_ level: LiveLevel) {
        self.level = level
    }

    func openAudioPrivacySettings() {
        NSWorkspace.shared.open(Self.audioPrivacyURL)
    }

    /// Asks the engine to measure the real delay (6 s of capture).
    func measureDelay() {
        guard phase == .running, measurement != .measuring else { return }
        measurement = .measuring
        controller?.send(.debugMeasureDelay)
    }

    /// Level for the meter, from 0 to 1: the RMS in dB between -60 and 0.
    func meter(_ stem: Stem) -> Double {
        guard let rms = levels[stem], rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(max((db + 60) / 60, 0), 1)
    }

    // MARK: - From the app

    /// What a new Live engine receives first, read at the moment of starting: a click on the transpose while
    /// the engine started was not sent (`ModeController.send` drops it), so it goes with the start.
    var startCommands: [Command] {
        [.startLive(level: level, mix: mix)] + (transpose.isOff ? [] : [.setTranspose(semitones: transpose.semitones)])
    }

    /// A new engine is about to be born: nothing the old one said is valid anymore.
    func resetForNewEngine() {
        phase = nil
        stats = nil
        levels = [:]
        permissionSuspected = false
        measurement = nil
        tempo = nil
        key = nil
        transpose = .off
    }

    /// Telemetry on only while the panel is open.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        // With the panel closed the engine stops analyzing: an old number must not show on reopening. If the
        // music did not pause meanwhile, the engine sends the key again at once.
        if !open {
            tempo = nil
            key = nil
        }
        controller?.send(.setTelemetry(open))
    }

    func handle(_ event: Event) {
        switch event {
        case .live(let newPhase):
            phase = newPhase
            // The engine starts with telemetry off: if the panel is open it is turned on again.
            if newPhase == .warming, panelOpen { controller?.send(.setTelemetry(true)) }
            if newPhase != .running, measurement == .measuring { measurement = nil }
        case .liveStats(let newStats):
            stats = newStats
        case .levels(let newLevels):
            levels = newLevels
            capturePermission.heard(levels: newLevels)
            if permissionSuspected, newLevels.values.contains(where: { $0 > 0 }) { permissionSuspected = false }
        case .permissionSuspected:
            if !capturePermission.confirmed { permissionSuspected = true }
        case .measuredDelay(let seconds):
            measurement = .done(seconds: seconds)
        case .tempo(let bpm):
            tempo = bpm
        case .key(let value):
            key = value
        case .failure(let failure):
            if failure.code == "measure" { measurement = .failed(failure) }
        default:
            break
        }
    }

    // MARK: - Sending the mix

    private func scheduleMixSend() {
        let now = ProcessInfo.processInfo.systemUptime
        switch throttle.request(at: now) {
        case .sendNow:
            controller?.send(.setMix(mix))
        case .sendAt(let at):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(at - now, 0)))
                guard let self else { return }
                self.throttle.fired(at: ProcessInfo.processInfo.systemUptime)
                self.controller?.send(.setMix(self.mix))
            }
        case .alreadyScheduled:
            break
        }
    }

    /// A saved mix is valid only if it has exactly the 4 Live stems and volumes between 0 and 1.
    private static func storedMix(_ defaults: UserDefaults) -> StemMix? {
        guard let data = defaults.data(forKey: mixKey),
              let mix = try? JSONDecoder().decode(StemMix.self, from: data),
              Set(mix.controls.keys) == Set(Stem.live),
              mix.controls.values.allSatisfy({ (0...1).contains($0.volume) })
        else { return nil }
        return mix
    }
}
