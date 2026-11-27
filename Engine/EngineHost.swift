// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import StelixCore
import Synchronization

/// Routes the `Command`s to the sub-engines and writes the `Event`s to stdout, from a serial queue.
/// Live and Studio: recording, 6-stem separation (Base in the engine,
/// Intermediate and Pro in the Python sidecar, see `SidecarJob`), player.
final class EngineHost: Sendable {
    private let commands = DispatchQueue(label: "io.github.stelix-app.stelix.engine.commands")
    private let stdout = DispatchQueue(label: "io.github.stelix-app.stelix.engine.stdout")
    private let exiting = Mutex(false)
    /// Stelix asked for the exit (`.shutdown`). An EOF on stdin without it means Stelix died.
    private let shutdownRequested = Mutex(false)
    private let live: LiveEngine
    private let recorder: Recorder
    private let separator: OfflineSeparator
    private let player: StudioPlayer
    private let keys: KeyScans
    /// Recordings and stems, until the user saves.
    private let scratch = StudioScratch()

    init() {
        let stdout = stdout
        live = LiveEngine(emit: { event in EngineHost.write(event, on: stdout) })
        let scratch = scratch
        recorder = Recorder(scratch: scratch, emit: { event in EngineHost.write(event, on: stdout) })
        // Where the player is, for the key windows: the ones there come first.
        let heard = Mutex(0.0)
        let player = StudioPlayer(emit: { event in
            if case .player(let position, _, _) = event { heard.withLock { $0 = position } }
            EngineHost.write(event, on: stdout)
        })
        self.player = player
        let keys = KeyScans(emit: { event in EngineHost.write(event, on: stdout) },
                            position: { heard.withLock { $0 } })
        self.keys = keys
        separator = OfflineSeparator(scratch: scratch, keys: keys, emit: { event in EngineHost.write(event, on: stdout) },
                                     finished: { result in
                                         player.load(result)
                                         // The new stems are in the player: the previous ones can be deleted.
                                         scratch.loaded(URL(fileURLWithPath: result.folder, isDirectory: true))
                                     })
    }

    func emit(_ event: Event) {
        Self.write(event, on: stdout)
    }

    private static func write(_ event: Event, on stdout: DispatchQueue) {
        guard let line = try? LineCodec.encode(event) else { return }
        stdout.async {
            // SIGPIPE is ignored: if Stelix is dead the write fails, and the EOF on stdin makes us exit.
            try? FileHandle.standardOutput.write(contentsOf: line)
        }
    }

    func handle(_ command: Command) {
        // Here, on the reader thread, not on the queue: the EOF that follows `.shutdown` must find it already noted.
        if command == .shutdown { shutdownRequested.withLock { $0 = true } }
        commands.async { [self] in
            switch command {
            case .startLive(let level, let mix):
                live.start(level: level, mix: mix)
            case .setLiveLevel(let level):
                live.setLevel(level)
            case .setMix(let mix):
                // Live and Studio never live in the same engine: the one not active keeps only the mix.
                live.setMix(mix)
                player.setMix(mix)
            case .stopLive:
                live.stop()
            case .setTelemetry(let on):
                live.setTelemetry(on)
                player.setTelemetry(on)
            case .debugMeasureDelay:
                live.measureDelay()
            case .setTranspose(let semitones):
                // Like the mix: Live and Studio never live in the same engine, the one not active keeps only the value.
                live.setTranspose(Transpose(semitones: semitones))
                player.setTranspose(Transpose(semitones: semitones))
            case .shutdown:
                exitOnce()
            case .startRecording:
                // Recording and separation together make no sense, and the recording's new folder
                // would prune that of the job in progress: the engine does not trust the app.
                if separator.isBusy {
                    emit(.failure(EngineFailure(.alreadySeparating)))
                } else {
                    recorder.start()
                }
            case .stopRecording:
                recorder.stop()
            case .cancelJob:
                if !separator.cancel() { recorder.cancel() }
            case .separateFile(let path, let level):
                if recorder.isRecording {
                    emit(.failure(EngineFailure(.alreadyRecording)))
                } else {
                    recorder.claim(path)
                    separator.separate(path: path, level: level)
                }
            case .player(let command):
                player.handle(command)
            case .loadStems(let result, let position):
                // Stems of an earlier engine: in the player, and their folder is the one to keep.
                scratch.loaded(URL(fileURLWithPath: result.folder, isDirectory: true))
                player.load(result, at: position)
            case .scanKeys(let path, let folder, let done):
                keys.resume(path: path, folder: folder, done: done)
            case .clearStudio:
                if separator.isBusy || recorder.isRecording { return }
                keys.stop()
                player.stopAndWait()
                scratch.clear()
            }
        }
    }

    /// Goes through the same command queue, so the order of the answers stays the order of arrival.
    func reportBadLine() {
        commands.async { [self] in
            emit(.failure(EngineFailure(.badCommand)))
        }
    }

    /// SIGTERM calls `exitOnce` from a global queue, not from main: teardown waits for queues that in
    /// turn may wait for main (the end of a separation), and from main it would
    /// block until SIGKILL. The closure is born here and not in `main.swift`, where it would be
    /// isolated to the MainActor and would stop at the executor check.
    func installSigterm() -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler { [self] in exitOnce() }
        source.resume()
        return source
    }

    /// The only way out: .shutdown, EOF on stdin and SIGTERM often arrive together
    /// (Stelix sends .shutdown and closes stdin), and two exit() in parallel would tear down twice.
    /// The first caller does the teardown and exits; the others wait here until the process ends.
    /// `endOfInput`: stdin closed. Without a `.shutdown` before it, Stelix is dead and the stems kept for it go too.
    func exitOnce(endOfInput: Bool = false) -> Never {
        let first = exiting.withLock { flag -> Bool in
            defer { flag = true }
            return !flag
        }
        if first {
            teardown(appAlive: !endOfInput || shutdownRequested.withLock { $0 })
            // `_exit`, not `exit`: MLX's static destructors free the Metal encoders, and if a
            // thread is still computing (Live warming up, a cancelled Base separation)
            // Metal aborts the process. Stdout is already flushed by `teardown`.
            _exit(0)
        }
        while true { pause() }
    }

    /// Stops the sub-engines and flushes stdout. Live fades over 40 ms, then `AudioDeviceStop`,
    /// then destroys IOProc, aggregate and tap: the original returns before the process ends.
    private func teardown(appAlive: Bool) {
        live.stopAndWait()
        // Player first: the separator can take a few tenths of a second to stop, and
        // meanwhile the stems must not play.
        player.stopAndWait()
        keys.stop()
        recorder.stopAndWait()
        separator.stopAndWait()
        // The stems of the player outlive the engine: the app shows them again in the next Studio
        // (it empties the folder itself, on Quit and after 10 minutes of closed panel). The rest goes,
        // and everything goes if Stelix is dead (Task 10.10).
        if !appAlive { engineLog("studio: Stelix is gone, the temporary folder goes too") }
        scratch.clearKeepingLoaded(appAlive: appAlive)
        stdout.sync {}
    }
}
