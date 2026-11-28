// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Studio player commands.
public enum PlayerCommand: Codable, Sendable, Equatable {
    case play, pause, seek(seconds: Double)
}

/// What Stelix asks StelixEngine, one JSON line per command on stdin.
public enum Command: Codable, Sendable, Equatable {
    case startLive(level: LiveLevel, mix: StemMix)
    case setLiveLevel(LiveLevel)
    case setMix(StemMix)
    case stopLive
    /// Records until `stopRecording` arrives, at most `AudioFileLoader.defaultMaxSeconds`.
    case startRecording
    /// Closes the recording and delivers it with `.recorded`.
    case stopRecording
    case separateFile(path: String, level: StudioLevel)
    case cancelJob
    case player(PlayerCommand)
    /// Stems the app still shows from an earlier Studio engine: into the player, paused at `position`.
    case loadStems(StemsResult, position: Double)
    /// The Studio forgets its stems (10 minutes of closed panel): the player empties, the temporary folder too.
    case clearStudio
    /// Telemetry on only while the panel is open.
    case setTelemetry(Bool)
    case debugMeasureDelay
    /// The transpose, from -12 to +12 (`Transpose.range`); 0 is off. Live and Studio never live in the same
    /// engine: like `setMix`, the one that is active takes it.
    case setTranspose(semitones: Int)
    /// The Studio's speed, from 50 to 125 percent (`Speed.range`); 100 is the track as it is. Only the
    /// Studio player takes it.
    case setSpeed(percent: Int)
    /// A new Studio engine goes on with the key windows of the stems in `folder` that `done` does not have,
    /// from their source at `path` (`KeyScan`).
    case scanKeys(path: String, folder: String, done: KeyScan?)
    case shutdown
}
