// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import StelixCore

/// All of Stelix's visible text lives here, and only here: stem,
/// level, preset and model names too, and the error sentences that StelixCore and the engine send
/// as codes (`FailureMessage`, `JobStep`).
///
/// Every sentence is `String(localized: "<key>", defaultValue: "<English>")`. English is the base
/// language; the Italian lives in `App/Resources/Localizable.xcstrings`. Interpolated values are
/// always `String`s (one per sentence), so the catalog sees them as `%@`.
/// `scripts/check-strings.py` checks that code and catalog agree.
enum Copy {
    static let appName = "Stelix"
    static var modeOriginal: String { String(localized: "mode.original", defaultValue: "Original") }
    static var modeLive: String { String(localized: "mode.live", defaultValue: "Live") }
    static var modeStudio: String { String(localized: "mode.studio", defaultValue: "Studio") }
    static var originalTitle: String { String(localized: "original.title", defaultValue: "Stelix is asleep.") }
    static var originalSubtitle: String { String(localized: "original.subtitle", defaultValue: "Your Mac sounds as usual.") }
    // The two hints answer each other: Live is the live take, Studio the quality (bigger models,
    // the whole song instead of a 7.8 s window read near its edge).
    static var originalLiveHint: String { String(localized: "original.liveHint", defaultValue: "real time, 4 stems as you listen") }
    static var originalLiveStoppedForSilence: String {
        String(localized: "original.liveStoppedForSilence", defaultValue: "Live turned off after 5 minutes of silence.")
    }
    static var originalStudioHint: String { String(localized: "original.studioHint", defaultValue: "higher quality, 6 stems from a song") }
    static var quit: String { String(localized: "quit", defaultValue: "Quit Stelix") }
    static let quitShortcut = "⌘Q"
    static var settings: String { String(localized: "settings", defaultValue: "Settings") }
    static var settingsLaunchAtLogin: String { String(localized: "settings.launchAtLogin", defaultValue: "Open Stelix at login") }
    static var settingsLoginFailed: String {
        String(localized: "settings.loginFailed", defaultValue: "Can't change this setting. Try System Settings › General › Login Items & Extensions.")
    }

    static var phasePreparing: String { String(localized: "phase.preparing", defaultValue: "Preparing…") }
    static var phaseActive: String { String(localized: "phase.active", defaultValue: "Ready") }
    static var phaseStopping: String { String(localized: "phase.stopping", defaultValue: "Stopping…") }

    static var liveModel: String { String(localized: "live.model", defaultValue: "Model") }
    static var liveDelay: String { String(localized: "live.delay", defaultValue: "Behind by") }
    static var liveWarming: String { String(localized: "live.warming", defaultValue: "Preparing the model…") }
    static var liveFilling: String { String(localized: "live.filling", defaultValue: "Filling the buffer…") }
    static var liveWaitingForAudio: String { String(localized: "live.waitingForAudio", defaultValue: "Waiting for your Mac's audio…") }
    static var liveRebuilding: String { String(localized: "live.rebuilding", defaultValue: "The output changed. Restarting…") }
    static var liveReady: String { String(localized: "live.ready", defaultValue: "Playing") }
    static var statLoad: String { String(localized: "stat.load", defaultValue: "load") }
    static var statModel: String { String(localized: "stat.model", defaultValue: "model") }
    static var statUnderruns: String { String(localized: "stat.underruns", defaultValue: "dropouts") }
    static var measured: String { String(localized: "stat.measured", defaultValue: "measured") }
    static var measuring: String { String(localized: "stat.measuring", defaultValue: "measuring…") }
    static let noValue = "—"
    static var stemOn: String { String(localized: "stem.on", defaultValue: "on") }
    static var stemOff: String { String(localized: "stem.off", defaultValue: "off") }
    // Tooltip of a stem's icon: it is the only place that says what holding it does.
    static var stemHelpOn: String { String(localized: "stem.help.on", defaultValue: "Click to mute · Hold to solo") }
    static var stemHelpOff: String { String(localized: "stem.help.off", defaultValue: "Click to unmute · Hold to solo") }
    /// VoiceOver action on a stem's icon.
    static var stemSolo: String { String(localized: "stem.solo", defaultValue: "Solo") }
    static var stemSoloHint: String { String(localized: "stem.soloHint", defaultValue: "Hold a stem to hear it alone") }
    static var liveBluetooth: String { String(localized: "live.bluetooth", defaultValue: "Bluetooth output: the delay may be higher.") }

    static var studioRecord: String { String(localized: "studio.record", defaultValue: "Record") }
    static var studioOrDrop: String { String(localized: "studio.orDrop", defaultValue: "or drop an audio file here") }
    static var studioChooseFile: String { String(localized: "studio.chooseFile", defaultValue: "Choose File…") }
    static var studioLevel: String { String(localized: "studio.level", defaultValue: "Level") }
    static var studioStop: String { String(localized: "studio.stop", defaultValue: "Stop") }
    static var studioShowInFinder: String { String(localized: "studio.showInFinder", defaultValue: "Show in Finder") }
    static var studioCancel: String { String(localized: "studio.cancel", defaultValue: "Cancel") }
    static var studioPlay: String { String(localized: "studio.play", defaultValue: "Play") }
    static var studioPause: String { String(localized: "studio.pause", defaultValue: "Pause") }
    static var studioToStart: String { String(localized: "studio.toStart", defaultValue: "Go to Beginning") }
    static var studioChangeModel: String { String(localized: "studio.changeModel", defaultValue: "Change Model") }
    static var tempoUnknown: String { String(localized: "tempo.unknown", defaultValue: "Tempo not detected") }

    /// 88.27 → "BPM: 88.3" (English), "BPM: 88,3" (Italian); `nil` → "BPM: —".
    /// "BPM" is the same in every language.
    static func bpm(_ value: Double?) -> String {
        "BPM: " + (value.map(oneDecimal) ?? noValue)
    }

    /// For VoiceOver: 88.27 → "88.3 beats per minute".
    static func bpmSpoken(_ value: Double?) -> String {
        guard let value else { return tempoUnknown }
        let number = oneDecimal(value)
        return String(localized: "tempo.accessibility", defaultValue: "\(number) beats per minute")
    }

    static var keyUnknown: String { String(localized: "key.unknown", defaultValue: "Key not detected") }

    /// "Key: Cm" (English), "Tonalità: Cm" (Italian), `nil` → "Key: —", like the BPM (Gabriele, 26/11).
    /// The key's name is the same in every language.
    static func key(_ key: MusicalKey?) -> String {
        let name = key?.name ?? noValue
        return String(localized: "key.label", defaultValue: "Key: \(name)")
    }

    /// For VoiceOver: "Key: F minor", or "Key not detected".
    static func keySpoken(_ key: MusicalKey?) -> String {
        guard let key else { return keyUnknown }
        let tonic = key.tonicName
        switch key.mode {
        case .major: return String(localized: "key.spoken.major", defaultValue: "Key: \(tonic) major")
        case .minor: return String(localized: "key.spoken.minor", defaultValue: "Key: \(tonic) minor")
        }
    }

    static var transpose: String { String(localized: "transpose.label", defaultValue: "Transpose") }

    /// In place of "Transpose" after a value the field refuses (Gabriele, 26/11).
    static var transposeRange: String {
        String(localized: "transpose.range", defaultValue: "From −12 to +12")
    }

    /// "+3 st", "−5 st" (with the minus sign, U+2212), "0 st": the same in every language.
    static func transposeValue(_ transpose: Transpose) -> String {
        let n = transpose.semitones
        return (n > 0 ? "+\(n)" : n < 0 ? "\u{2212}\(-n)" : "0") + " st"
    }

    /// For VoiceOver: "3 semitones up", "1 semitone down", "No transpose".
    static func transposeSpoken(_ transpose: Transpose) -> String {
        let n = transpose.semitones
        let count = String(abs(n))
        switch n {
        case 0: return String(localized: "transpose.spoken.off", defaultValue: "No transpose")
        case 1: return String(localized: "transpose.spoken.up.one", defaultValue: "1 semitone up")
        case -1: return String(localized: "transpose.spoken.down.one", defaultValue: "1 semitone down")
        case 2...: return String(localized: "transpose.spoken.up", defaultValue: "\(count) semitones up")
        default: return String(localized: "transpose.spoken.down", defaultValue: "\(count) semitones down")
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
    static var studioSave: String { String(localized: "studio.save", defaultValue: "Save") }
    static var studioNewRecording: String { String(localized: "studio.newRecording", defaultValue: "New Recording") }
    static var studioRecordingName: String { String(localized: "studio.recordingName", defaultValue: "Recording") }
    static var studioMore: String { String(localized: "studio.more", defaultValue: "More Actions") }
    static var studioBaseHint: String {
        String(localized: "studio.baseHint", defaultValue: "Base is a quick preview. For quality, use Intermediate or Pro.")
    }

    static var retry: String { String(localized: "retry", defaultValue: "Try Again") }
    static var close: String { String(localized: "close", defaultValue: "Close") }
    static var errorEngineStopped: String {
        String(localized: "error.engineStopped", defaultValue: "The engine stopped. Your audio is back to normal.")
    }
    static var errorEngineStart: String { String(localized: "error.engineStart", defaultValue: "The engine didn't start.") }
    static var errorTimeout: String { String(localized: "error.timeout", defaultValue: "The engine didn't respond in time.") }
    static var errorFileNoAccess: String { String(localized: "error.fileNoAccess", defaultValue: "Can't read this file.") }
    static var errorSave: String { String(localized: "error.save", defaultValue: "Can't save the stems to Music.") }
    static var errorSaveNoSpace: String {
        String(localized: "error.saveNoSpace", defaultValue: "There isn't enough space on the disk to save the stems.")
    }
    static var permissionTitle: String { String(localized: "permission.title", defaultValue: "Stelix can't hear your Mac's audio.") }
    static var permissionBody: String {
        String(localized: "permission.body",
               defaultValue: "If something is playing, allow Stelix in System Settings, Privacy & Security, System Audio Recording.")
    }
    static var permissionOpen: String { String(localized: "permission.open", defaultValue: "Open Settings") }

    // MARK: - Formats (digits follow the user's locale)

    /// 0.98 → "0.98 s" (English), "0,98 s" (Italian)
    static func delay(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) s"
    }

    /// 0.21 → "21%" (the fraction goes from 0 to 1)
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// 96.4 → "96 ms" (the argument is already in milliseconds, like `LiveStats.modelMs`)
    static func milliseconds(_ ms: Double) -> String {
        "\(Int(ms.rounded())) ms"
    }

    /// A whole count: 1200 → "1,200" (English), "1200" (Italian)
    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// "2026-11-08 15.30 Song" → "Saved in Music › Stelix › 2026-11-08 15.30 Song"
    static func savedIn(_ folder: String) -> String {
        String(localized: "studio.savedIn", defaultValue: "Saved in Music › Stelix › \(folder)")
    }

    /// 4.2 → "0:04", 75 → "1:15"
    static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// "0:04 / 0:10"
    static func clockPair(_ position: Double, _ duration: Double) -> String {
        "\(clock(position)) / \(clock(duration))"
    }

    /// "0.1 (1)" → "Version 0.1 (1)"
    static func version(_ value: String) -> String {
        String(localized: "settings.version", defaultValue: "Version \(value)")
    }

    static func name(_ mode: Mode) -> String {
        switch mode {
        case .original: modeOriginal
        case .live: modeLive
        case .studio: modeStudio
        }
    }

    static func phase(_ phase: ModePhase) -> String {
        switch phase {
        case .preparing: phasePreparing
        case .active: phaseActive
        case .stopping: phaseStopping
        case .failed(let failure): Self.failure(failure)
        }
    }

    // MARK: - Names

    static func name(_ stem: Stem) -> String {
        switch stem {
        case .vocals: String(localized: "stem.vocals", defaultValue: "Vocals")
        case .drums: String(localized: "stem.drums", defaultValue: "Drums")
        case .bass: String(localized: "stem.bass", defaultValue: "Bass")
        case .other: String(localized: "stem.other", defaultValue: "Other")
        case .piano: String(localized: "stem.piano", defaultValue: "Piano")
        case .guitar: String(localized: "stem.guitar", defaultValue: "Guitar")
        }
    }

    static func name(_ level: LiveLevel) -> String {
        switch level {
        case .base: levelBase
        case .intermediate: levelIntermediate
        case .pro: levelPro
        }
    }

    static func name(_ level: StudioLevel) -> String {
        switch level {
        case .base: levelBase
        case .intermediate: levelIntermediate
        case .pro: levelPro
        }
    }

    private static var levelBase: String { String(localized: "level.base", defaultValue: "Base") }
    private static var levelIntermediate: String { String(localized: "level.intermediate", defaultValue: "Intermediate") }
    private static var levelPro: String { String(localized: "level.pro", defaultValue: "Pro") }

    static func name(_ preset: Preset) -> String {
        switch preset {
        case .soloVoice: String(localized: "preset.soloVoice", defaultValue: "Vocals Only")
        case .noVoice: String(localized: "preset.noVoice", defaultValue: "No Vocals")
        case .all: String(localized: "preset.all", defaultValue: "All")
        }
    }

    /// Model names are proper names: the same in every language.
    static func name(_ model: ModelID) -> String {
        switch model {
        case .htdemucs: "htdemucs"
        case .htdemucsFT: "htdemucs_ft"
        case .htdemucs6s: "htdemucs_6s"
        case .roformerSW: "BS-Roformer SW"
        case .roformerVocals: "BS-Roformer ep_317"
        }
    }

    /// The saved stem's file name in Music, in the user's language: "vocals.wav", "voce.wav".
    static func savedFileName(_ stem: Stem) -> String {
        switch stem {
        case .vocals: String(localized: "file.vocals", defaultValue: "vocals.wav")
        case .drums: String(localized: "file.drums", defaultValue: "drums.wav")
        case .bass: String(localized: "file.bass", defaultValue: "bass.wav")
        case .other: String(localized: "file.other", defaultValue: "other.wav")
        case .piano: String(localized: "file.piano", defaultValue: "piano.wav")
        case .guitar: String(localized: "file.guitar", defaultValue: "guitar.wav")
        }
    }

    static var savedRecordingFileName: String { String(localized: "file.recording", defaultValue: "recording.wav") }

    // MARK: - Models

    /// 639_331_213 → "639 MB" (digits follow the user's region)
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// The banner of a Live level whose model is missing: what it's for and how much, no names.
    static func modelBanner(live level: LiveLevel, size: String) -> String {
        switch level {
        case .base, .intermediate:
            String(localized: "model.banner.live", defaultValue: "Live needs its model to start: \(size).")
        case .pro:
            String(localized: "model.banner.livePro", defaultValue: "Pro uses a larger model: \(size).")
        }
    }

    /// The banner of a Studio level, by what's missing (Pro may already have SW from Intermediate).
    static func modelBanner(studio level: StudioLevel, missing: [ModelID], size: String) -> String {
        switch level {
        case .base:
            return String(localized: "model.banner.studio", defaultValue: "Studio needs its model to separate: \(size).")
        case .intermediate:
            return String(localized: "model.banner.studioIntermediate", defaultValue: "Intermediate uses a larger model: \(size).")
        case .pro:
            if missing == [.roformerVocals] {
                return String(localized: "model.banner.studioProVocals", defaultValue: "Pro uses an extra model for vocals: \(size).")
            }
            if missing == [.roformerSW] {
                return String(localized: "model.banner.studioProSW", defaultValue: "Pro also uses the Intermediate model: \(size).")
            }
            return String(localized: "model.banner.studioPro", defaultValue: "Pro uses two larger models: \(size).")
        }
    }

    /// "Live Pro · 672 MB": what a model is for and its size, in a settings row.
    static func modelRow(_ model: ModelID, size: Int64) -> String { "\(modelUse(model)) · \(bytes(size))" }

    /// In Original while some model is missing, until closed.
    static func modelAllOffer(_ size: String) -> String {
        String(localized: "model.allOffer", defaultValue: "Download all models (\(size)), or each one when you first need it.")
    }
    static var modelDownloadAll: String { String(localized: "model.downloadAll", defaultValue: "Download All Models…") }
    static var modelNotNow: String { String(localized: "model.notNow", defaultValue: "Not Now") }

    static var modelDownloadEllipsis: String { String(localized: "model.downloadEllipsis", defaultValue: "Download…") }
    static var modelDownload: String { String(localized: "model.download", defaultValue: "Download") }
    static var modelCancel: String { String(localized: "model.cancel", defaultValue: "Cancel") }
    static var modelRemove: String { String(localized: "model.remove", defaultValue: "Remove") }
    static var modelAdd: String { String(localized: "model.add", defaultValue: "Add Model…") }
    static var modelsTitle: String { String(localized: "model.title", defaultValue: "Models") }
    static var modelRemoveHint: String {
        String(localized: "model.removeHint", defaultValue: "To remove a model, switch to Original.")
    }
    static var modelChecking: String { String(localized: "model.checking", defaultValue: "Checking the file…") }
    static func modelAdded(_ model: String) -> String {
        String(localized: "model.added", defaultValue: "Added \(model).")
    }
    /// "Add Model…" took one file of a model that still lacks others: `missing` names them.
    static func modelAddedPart(_ model: String, missing: String) -> String {
        String(localized: "model.addedPart", defaultValue: "Added a file of \(model). Still missing: \(missing).")
    }
    static func modelRemoveConfirm(_ model: String, size: String) -> String {
        String(localized: "model.removeConfirm",
               defaultValue: "Remove \(model)? To use it later, you'll need to download it again (\(size)).")
    }
    /// "120 MB / 639 MB" → "Downloading… 120 MB / 639 MB"
    static func modelProgress(_ amounts: String) -> String {
        String(localized: "model.progress", defaultValue: "Downloading… \(amounts)")
    }

    /// Below the notice's rows: the terms, and where the files come from.
    static var modelTerms: String {
        String(localized: "model.terms",
               defaultValue: "For personal, non-commercial use. Stelix doesn't host models: you download them from their source. Each file is checked when it arrives and deleted if it doesn't match.")
    }
    /// Only when SW is among the models, after its license line: the choice is the user's.
    static var modelMirrorWarning: String {
        String(localized: "model.mirrorWarning", defaultValue: "Downloading it from there is your choice.")
    }

    /// What a model is for, in the settings list.
    static func modelUse(_ model: ModelID) -> String {
        switch model {
        case .htdemucs: String(localized: "model.use.htdemucs", defaultValue: "Live Base and Intermediate")
        case .htdemucsFT: String(localized: "model.use.htdemucsFT", defaultValue: "Live Pro")
        case .htdemucs6s: String(localized: "model.use.htdemucs6s", defaultValue: "Studio Base")
        case .roformerSW: String(localized: "model.use.roformerSW", defaultValue: "Studio Intermediate and Pro")
        case .roformerVocals: String(localized: "model.use.roformerVocals", defaultValue: "Studio Pro, vocals")
        }
    }

    static func modelAuthor(_ model: ModelID) -> String {
        switch model {
        case .htdemucs, .htdemucsFT, .htdemucs6s:
            String(localized: "model.author.demucs", defaultValue: "Alexandre Défossez (Meta), MLX conversion by ssmall256")
        case .roformerSW: String(localized: "model.author.unknown", defaultValue: "Author not stated")
        case .roformerVocals: "viperx (UVR)"
        }
    }

    /// The license status in a few words, as facts: what the author did or didn't say. Demucs: the
    /// author's README, not the mirror's "MIT". Worded to sound less
    /// alarming without dropping any fact.
    static func license(_ license: ModelLicense) -> String {
        switch license {
        case .demucsUnclear: String(localized: "model.license.demucs", defaultValue: "The author hasn't set a license for the weights.")
        case .undeclared: String(localized: "model.license.undeclared", defaultValue: "The author hasn't set a license.")
        case .undeclaredUnverified:
            String(localized: "model.license.unverified", defaultValue: "Shared by python-audio-separator, without the original author or a license.")
        }
    }

    static func modelFailure(_ failure: ModelLibrary.Failure) -> String {
        switch failure {
        case .unavailable:
            String(localized: "model.error.unavailable", defaultValue: "This model is no longer available from this source.")
        case .network:
            String(localized: "model.error.network", defaultValue: "The download stopped. Check the connection and try again.")
        case .checksum:
            String(localized: "model.error.checksum", defaultValue: "The downloaded file doesn't match. It was deleted.")
        case .write: String(localized: "model.error.write", defaultValue: "Can't write the model to disk.")
        case .notInCatalog: String(localized: "model.error.notInCatalog", defaultValue: "This file isn't one of Stelix's models.")
        case .notEnoughSpace(let needed):
            String(localized: "model.error.space", defaultValue: "Not enough space on the disk: \(bytes(needed)) needed.")
        }
    }

    // MARK: - About

    static var about: String { String(localized: "about.title", defaultValue: "About Stelix") }
    static var aboutBack: String { String(localized: "about.back", defaultValue: "Back") }
    static var aboutFreeSoftware: String {
        String(localized: "about.freeSoftware", defaultValue: "Stelix is free and open source software under the GNU GPL v3: you can use, share and modify it. As the license says, it comes as is, without warranty.")
    }
    static var aboutLicense: String { String(localized: "about.license", defaultValue: "License") }
    static var aboutSource: String { String(localized: "about.source", defaultValue: "Source Code") }
    static var aboutPrivacy: String { String(localized: "about.privacy", defaultValue: "Privacy Policy") }
    static var aboutNotices: String { String(localized: "about.notices", defaultValue: "Third-Party Notices") }
    /// The LGPL asks for the libraries' copyright notices next to the app's own, and for where their license is.
    static var aboutLGPL: String {
        String(localized: "about.lgpl", defaultValue: "Includes LAME (Copyright The LAME Project) and the SoX Resampler library (Copyright 2007-2018 Rob Sykes), under the GNU LGPL. Their licenses are in Third-Party Notices.")
    }
    static var aboutCredits: String { String(localized: "about.credits", defaultValue: "Models") }
    static var aboutCreditsNote: String {
        String(localized: "about.creditsNote", defaultValue: "Stelix doesn't host models: each one is downloaded from its source.")
    }
    /// The holder is a name: the same in every language. "Copyright", not the sign: the lint reads
    /// U+00A9 as an emoji (Extended_Pictographic), and the word is what the GPL itself uses.
    static func copyright(_ holder: String) -> String { "Copyright 2026 \(holder)" }

    // MARK: - Steps and errors

    static func step(_ step: JobStep) -> String {
        switch step {
        case .readingFile: String(localized: "step.readingFile", defaultValue: "Reading the file…")
        case .preparingModel: String(localized: "step.preparingModel", defaultValue: "Preparing the model…")
        case .separating: String(localized: "step.separating", defaultValue: "Separating…")
        case .loadingVocalsModel: String(localized: "step.loadingVocalsModel", defaultValue: "Loading the vocals model…")
        case .separatingVocals: String(localized: "step.separatingVocals", defaultValue: "Separating the vocals…")
        case .loadingInstrumentsModel:
            String(localized: "step.loadingInstrumentsModel", defaultValue: "Loading the instruments model…")
        case .separatingInstruments: String(localized: "step.separatingInstruments", defaultValue: "Separating the instruments…")
        case .rebuildingOther: String(localized: "step.rebuildingOther", defaultValue: "Rebuilding Other…")
        case .writingStems: String(localized: "step.writingStems", defaultValue: "Writing the stems…")
        }
    }

    /// The sentence for an error. `detail` is a `rawValue` (stem, level, model) or the minutes of `tooLong`.
    static func failure(_ failure: EngineFailure) -> String {
        let detail = failure.detail
        let stem = detail.flatMap(Stem.init(rawValue:)).map(name)
        switch failure.message {
        case .noStems: return String(localized: "failure.noStems", defaultValue: "There are no stems to play.")
        case .stemUnreadable:
            if let stem { return String(localized: "failure.stemUnreadable.one", defaultValue: "Can't open the \(stem) stem.") }
            return String(localized: "failure.stemUnreadable", defaultValue: "Can't open the stems.")
        case .stemsUnwritable: return String(localized: "failure.stemsUnwritable", defaultValue: "Can't write the stems.")
        case .recordingUnwritable:
            return String(localized: "failure.recordingUnwritable", defaultValue: "Can't write the recording.")
        case .outputUnplayable:
            return String(localized: "failure.outputUnplayable", defaultValue: "Can't play through the audio output.")
        case .separationFailed: return String(localized: "failure.separationFailed", defaultValue: "The separation failed.")
        case .separationIncomplete:
            return String(localized: "failure.separationIncomplete", defaultValue: "The separation didn't finish.")
        case .modelLoad:
            if let level = detail.flatMap(LiveLevel.init(rawValue:)).map(name) {
                return String(localized: "failure.modelLoad.one", defaultValue: "Can't load the \(level) model.")
            }
            return String(localized: "failure.modelLoad", defaultValue: "Can't load the model.")
        case .modelNotReady: return String(localized: "failure.modelNotReady", defaultValue: "The model isn't ready.")
        case .modelTooSlow:
            // The level is in `detail` when this Mac is too slow for it (`LiveSchedule`).
            switch detail.flatMap(LiveLevel.init(rawValue:)) {
            case .base:
                return String(localized: "failure.modelTooSlow.base", defaultValue: "This Mac is too slow for Live.")
            case let level?:
                let levelName = name(level)
                return String(localized: "failure.modelTooSlow.one",
                              defaultValue: "This Mac is too slow for the \(levelName) level. Try a lower one.")
            case nil:
                return String(localized: "failure.modelTooSlow", defaultValue: "The model can't keep up.")
            }
        case .modelUnexpected:
            if let model = detail.flatMap(ModelID.init(rawValue:)).map(name) {
                return String(localized: "failure.modelUnexpected.one", defaultValue: "The \(model) model isn't the expected one.")
            }
            return String(localized: "failure.modelUnexpected", defaultValue: "The model isn't the expected one.")
        case .modelMissingStem:
            if let stem {
                return String(localized: "failure.modelMissingStem.one", defaultValue: "The model didn't return the \(stem) stem.")
            }
            return String(localized: "failure.modelMissingStem", defaultValue: "The model didn't return all the stems.")
        case .alreadyRecording: return String(localized: "failure.alreadyRecording", defaultValue: "Already recording.")
        case .alreadySeparating:
            return String(localized: "failure.alreadySeparating", defaultValue: "Already separating a file.")
        case .recordingCancelled: return String(localized: "failure.recordingCancelled", defaultValue: "Recording canceled.")
        case .separationCancelled: return String(localized: "failure.separationCancelled", defaultValue: "Separation canceled.")
        case .noAudio: return String(localized: "failure.noAudio", defaultValue: "No audio is coming from your Mac.")
        case .recordingInterrupted:
            return String(localized: "failure.recordingInterrupted", defaultValue: "The recording was interrupted.")
        case .silentRecording:
            return String(localized: "failure.silentRecording", defaultValue: "No audio came in: your Mac was silent.")
        case .measureNotLive:
            return String(localized: "failure.measureNotLive", defaultValue: "To measure the delay, Live has to be playing.")
        case .measureOutputChanged:
            return String(localized: "failure.measureOutputChanged", defaultValue: "The measurement stopped: the output changed.")
        case .measureNoSignal: return String(localized: "failure.measureNoSignal", defaultValue: "No signal to measure.")
        case .missingWeights:
            if let model = detail.flatMap(ModelID.init(rawValue:)).map(name) {
                return String(localized: "failure.missingWeights.one", defaultValue: "The \(model) model is missing.")
            }
            return String(localized: "failure.missingWeights", defaultValue: "A model is missing.")
        case .outputSetup: return String(localized: "failure.outputSetup", defaultValue: "Can't set up the audio output.")
        case .badCommand: return String(localized: "failure.badCommand", defaultValue: "Unknown command.")
        case .noOutput: return String(localized: "failure.noOutput", defaultValue: "Can't find your Mac's audio output.")
        case .tap: return String(localized: "failure.tap", defaultValue: "Can't listen to your Mac's audio.")
        case .audioStart: return String(localized: "failure.audioStart", defaultValue: "Can't start the audio.")
        case .sidecarMissing:
            return String(localized: "failure.sidecarMissing", defaultValue: "Can't find the engine for Intermediate and Pro.")
        case .musicFolder: return String(localized: "failure.musicFolder", defaultValue: "Can't create the folder in Music.")
        case .tempFolder: return String(localized: "failure.tempFolder", defaultValue: "Can't create the temporary folder.")
        case .unsupported: return String(localized: "failure.unsupported", defaultValue: "This file has no audio.")
        case .tooLong:
            if let minutes = detail {
                return String(localized: "failure.tooLong.one", defaultValue: "The file is too long: \(minutes) minutes at most.")
            }
            return String(localized: "failure.tooLong", defaultValue: "The file is too long.")
        case .engineLaunch, .engineExited: return errorEngineStart
        case .engineTimeout: return errorTimeout
        case .engineStopped: return errorEngineStopped
        case .unknown: return String(localized: "failure.unknown", defaultValue: "Something went wrong.")
        case .fileNoAccess: return errorFileNoAccess
        case .saveFailed: return errorSave
        case .saveNoSpace: return errorSaveNoSpace
        }
    }

    // MARK: - Updates (Task 10.11, window in 1.1.0)

    static func updateAvailable(_ version: String) -> String {
        String(localized: "update.available", defaultValue: "Stelix \(version) is available")
    }
    static func updateSubtitle(_ date: String, size: String) -> String {
        String(localized: "update.subtitle", defaultValue: "Released on \(date) · \(size)")
    }
    static var updateFullNotes: String {
        String(localized: "update.fullNotes", defaultValue: "Full Release Notes on GitHub")
    }
    static var updateSource: String {
        String(localized: "update.source", defaultValue: "From GitHub. Your models, settings and audio permission stay.")
    }
    static func updateReady(_ version: String) -> String {
        String(localized: "update.ready", defaultValue: "Stelix \(version) is in Downloads.")
    }
    static var updateReadyHint: String {
        String(localized: "update.readyHint",
               defaultValue: "Quit Stelix, then drag the new one to Applications and choose Replace.")
    }
    static var updateQuitAndOpen: String { String(localized: "update.quitAndOpen", defaultValue: "Quit and Open the DMG") }
    static var updateLater: String { String(localized: "update.later", defaultValue: "Later") }
    static var updateSkip: String { String(localized: "update.skip", defaultValue: "Skip This Version") }

    static func updateFailure(_ failure: UpdateCenter.Failure) -> String {
        switch failure {
        case .network: modelFailure(.network)
        case .unavailable: String(localized: "update.error.unavailable",
                                  defaultValue: "This version is no longer on GitHub. Try again later.")
        case .checksum: modelFailure(.checksum)
        case .verification: String(localized: "update.error.verification",
                                   defaultValue: "This file isn't a genuine Stelix update. It was deleted.")
        case .write: String(localized: "update.error.write", defaultValue: "Can't save the file in Downloads.")
        }
    }

    static var settingsUpdates: String {
        String(localized: "settings.updates", defaultValue: "Check for updates automatically")
    }
    static var settingsCheckNow: String { String(localized: "settings.checkNow", defaultValue: "Check Now") }
    static var settingsChecking: String { String(localized: "settings.checking", defaultValue: "Checking…") }
    static var settingsUpToDate: String { String(localized: "settings.upToDate", defaultValue: "Stelix is up to date.") }
    static var settingsCheckFailed: String { String(localized: "settings.checkFailed", defaultValue: "Can't check now.") }
    static func settingsUpdateAvailable(_ version: String) -> String {
        String(localized: "settings.updateAvailable", defaultValue: "Stelix \(version) available")
    }
}
