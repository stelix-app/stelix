// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

public enum LivePhase: Codable, Sendable, Equatable {
    /// `waitingForAudio`: the pipeline exists but the Mac is silent, and the tap gives no frames until something
    /// plays. Filling restarts with `filling` as soon as audio arrives.
    case warming, filling(fraction: Double), waitingForAudio, running, rebuilding, stopped, stoppedForSilence
}

public struct LiveStats: Codable, Sendable, Equatable {
    /// Real delay: most recent input frame minus the frame being played.
    public var delaySeconds: Double
    public var modelMs: Double
    /// p95 of modelMs divided by `LiveLevel.modelBudget`.
    public var load: Double
    public var underruns: Int
    public var outputIsBluetooth: Bool

    public init(delaySeconds: Double, modelMs: Double, load: Double, underruns: Int, outputIsBluetooth: Bool) {
        self.delaySeconds = delaySeconds
        self.modelMs = modelMs
        self.load = load
        self.underruns = underruns
        self.outputIsBluetooth = outputIsBluetooth
    }
}

public struct StemsResult: Codable, Sendable, Equatable {
    public var folder: String
    public var files: [Stem: String]
    public var duration: Double
    /// 600 peaks per stem.
    public var waveforms: [Stem: [Float]]
    /// Beat times of the source track, in seconds; `nil` before macOS 27, if the analysis failed,
    /// or from an engine without it.
    public var beats: [Double]?

    public init(folder: String, files: [Stem: String], duration: Double, waveforms: [Stem: [Float]],
                beats: [Double]? = nil) {
        self.folder = folder
        self.files = files
        self.duration = duration
        self.waveforms = waveforms
        self.beats = beats
    }

    /// Seconds each side of a point in which some stem must be above the threshold for a tempo to show.
    public static let tempoSilenceSpan = 1.0

    /// The local tempo at `time`, or `nil`: no beats, or the stems are silent there (the analysis
    /// puts beats on silence too).
    public func bpm(at time: Double) -> Double? {
        guard let beats else { return nil }
        if isSilent(around: time) { return nil }
        return TempoMap(beats: beats).bpm(at: time)
    }

    private func isSilent(around time: Double) -> Bool {
        let peaks = waveforms.values.filter { !$0.isEmpty }
        guard duration > 0, !peaks.isEmpty else { return false }
        return !peaks.contains { stem in
            let bins = Double(stem.count)
            let low = max(0, Int(((time - Self.tempoSilenceSpan) / duration * bins).rounded(.down)))
            let high = min(stem.count - 1, Int(((time + Self.tempoSilenceSpan) / duration * bins).rounded(.up)))
            guard low <= high else { return false }
            return stem[low...high].contains { $0 >= LiveIdleTimer.threshold }
        }
    }
}

/// What went wrong, one sentence per case: the app chooses the text (`Copy.failure`).
/// `code` is the error family, the one the logic reads ("cancelled", "measure", "busy"…).
public enum FailureMessage: String, Codable, Sendable, CaseIterable {
    case noStems, stemUnreadable, stemsUnwritable, recordingUnwritable, outputUnplayable
    case separationFailed, separationIncomplete
    case modelLoad, modelNotReady, modelTooSlow, modelUnexpected, modelMissingStem
    case alreadyRecording, alreadySeparating
    case recordingCancelled, separationCancelled
    case noAudio, recordingInterrupted, silentRecording
    case measureNotLive, measureOutputChanged, measureNoSignal
    case missingWeights
    case outputSetup, badCommand, noOutput, tap, audioStart
    case sidecarMissing, musicFolder, tempFolder
    case unsupported, tooLong
    case engineLaunch, engineTimeout, engineExited, engineStopped
    case unknown
    /// Found by the app before asking the engine anything.
    case fileNoAccess, saveFailed, saveNoSpace

    public var code: String {
        switch self {
        case .noStems: "noStems"
        case .stemUnreadable, .stemsUnwritable, .recordingUnwritable: "file"
        case .outputUnplayable: "output"
        case .separationFailed, .separationIncomplete, .modelLoad, .modelNotReady, .modelTooSlow,
             .modelUnexpected, .modelMissingStem: "model"
        case .alreadyRecording, .alreadySeparating: "busy"
        case .recordingCancelled, .separationCancelled: "cancelled"
        case .noAudio: "stall"
        case .recordingInterrupted: "overrun"
        case .silentRecording: "empty"
        case .measureNotLive, .measureOutputChanged, .measureNoSignal: "measure"
        case .missingWeights: "weights"
        case .outputSetup: "aggregate"
        case .badCommand: "badCommand"
        case .noOutput: "noOutput"
        case .tap: "tap"
        case .audioStart: "start"
        case .sidecarMissing: "sidecar"
        case .musicFolder, .tempFolder: "folder"
        case .unsupported: "unsupported"
        case .tooLong: "tooLong"
        case .engineLaunch: "launch"
        case .engineTimeout: "timeout"
        case .engineExited: "exit"
        case .engineStopped: "crash"
        case .unknown: "unknown"
        case .fileNoAccess: "access"
        case .saveFailed, .saveNoSpace: "save"
        }
    }
}

/// An error from the engine (or the app). `detail` is never text to show: it is a `rawValue`
/// (a stem, a level, a `ModelID`) or the cap in minutes for `tooLong`.
public struct EngineFailure: Codable, Sendable, Equatable, Error {
    public var code: String
    public var message: FailureMessage
    public var detail: String?

    public init(_ message: FailureMessage, detail: String? = nil) {
        self.code = message.code
        self.message = message
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case code, message, detail }

    /// A message this app does not know (a newer engine) becomes `.unknown`, with its code.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .message)
        message = FailureMessage(rawValue: raw) ?? .unknown
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? message.code
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// Where a Studio job stands. The app chooses the text (`Copy.step`).
public enum JobStep: String, Codable, Sendable {
    case readingFile, preparingModel, separating
    case loadingVocalsModel, separatingVocals, loadingInstrumentsModel, separatingInstruments
    case rebuildingOther, writingStems
}

/// What StelixEngine tells Stelix, one JSON line per event on stdout.
public enum Event: Codable, Sendable, Equatable {
    case ready
    case live(LivePhase)
    case liveStats(LiveStats)
    case levels([Stem: Float])
    /// At 10 Hz during recording: the seconds written and the peak (0...1) of each 50 ms block
    /// written since the previous event.
    case recording(seconds: Double, peaks: [Float])
    case recorded(path: String)
    case job(progress: Double, step: JobStep)
    case stemsReady(StemsResult)
    case player(position: Double, duration: Double, playing: Bool)
    case permissionSuspected
    case measuredDelay(seconds: Double)
    /// Live tempo, every `LiveTempoWindow.hop` s with the panel open; `nil` on silence.
    case tempo(bpm: Double?)
    case failure(EngineFailure)
}

extension EngineFailure {
    /// Any error as `EngineFailure`: missing weights become `missingWeights` with the
    /// model in `detail`, an `EngineFailure` stays as it is, the rest is `fallback`.
    public init(_ error: Error, fallback: EngineFailure) {
        if let failure = error as? EngineFailure {
            self = failure
        } else if case let ModelStoreError.missing(id)? = error as? ModelStoreError {
            self.init(.missingWeights, detail: id.rawValue)
        } else {
            self = fallback
        }
    }
}
