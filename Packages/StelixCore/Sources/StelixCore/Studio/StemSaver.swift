// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Foundation
import Synchronization

/// Save: copies the stems from the temporary folder into a new `StudioFolder` folder
/// (`~/Music/Stelix/YYYY-MM-DD HH.mm[ name]`). It copies, not moves: the player has them open.
public enum StemSaver {
    /// The 6 stems with the names in `names`, plus `recording` as `recordingName` if present. The names are given by
    /// the app, in the language of whoever uses Stelix ("voce.wav" in Italian). If anything fails, the
    /// new folder is deleted and the error propagates.
    ///
    /// With `provenance` every saved stem says, in its own metadata, which software and which models
    /// made it (`WavInfo`). Only the copies: the temporary stems are open in the player. The
    /// recording is the audio as it was captured, and stays as it is.
    ///
    /// With a `transpose` other than 0 the folder carries the semitones; the drums and the recording are
    /// copied as they are, the other 5 stems go through `StemTransposer`, in parallel. `progress` gets 0...1
    /// at most every 1%, ending at 1; `cancel` stops it with `CancellationError`, and the folder goes as
    /// after any error.
    public static func save(_ result: StemsResult, recording: URL?, sourceName: String?,
                            root: URL = StudioFolder.defaultRoot, date: Date,
                            names: (Stem) -> String, recordingName: String,
                            provenance: StemProvenance? = nil, transpose: Transpose = .off,
                            cancel: SaveCancel? = nil,
                            progress: (@Sendable (Double) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = try StudioFolder.make(root: root, date: date, sourceName: sourceName, transpose: transpose)
        do {
            var shifted: [(source: URL, saved: URL)] = []
            for stem in Stem.studio {
                guard let path = result.files[stem] else { throw CocoaError(.fileNoSuchFile) }
                let saved = folder.appending(path: names(stem))
                if transpose.isOff || stem == .drums {
                    try fm.copyItem(at: URL(fileURLWithPath: path), to: saved)
                } else {
                    shifted.append((URL(fileURLWithPath: path), saved))
                }
            }
            if !shifted.isEmpty {
                try transposeAll(shifted, semitones: transpose.semitones, cancel: cancel, progress: progress)
            }
            if let provenance {
                for stem in Stem.studio {
                    try WavInfo.append(software: provenance.software, comment: provenance.comment,
                                       to: folder.appending(path: names(stem)))
                }
            }
            if let recording {
                try fm.copyItem(at: recording, to: folder.appending(path: recordingName))
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// One time pitch per stem, all together. The first error stops the others and is thrown.
    private static func transposeAll(_ stems: [(source: URL, saved: URL)], semitones: Int, cancel: SaveCancel?,
                                     progress: (@Sendable (Double) -> Void)?) throws {
        let total = stems.reduce(0) { sum, stem in
            sum + Int((try? AVAudioFile(forReading: stem.source).length) ?? 0)
        }
        let stop = SaveCancel(parent: cancel)
        let state = Mutex<(done: [Int], reported: Double, error: (any Error)?)>(
            (Array(repeating: 0, count: stems.count), -1, nil))
        DispatchQueue.concurrentPerform(iterations: stems.count) { index in
            do {
                try StemTransposer.transpose(stems[index].source, to: stems[index].saved, semitones: semitones,
                                             cancel: stop) { frames in
                    state.withLock { state in
                        state.done[index] = frames
                        let fraction = total > 0 ? Double(state.done.reduce(0, +)) / Double(total) : 1
                        guard fraction == 1 || fraction - state.reported >= 0.01 else { return }
                        state.reported = fraction
                        progress?(fraction)
                    }
                }
            } catch {
                state.withLock { if $0.error == nil { $0.error = error } }
                stop.cancel()
            }
        }
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { state in
            if state.reported < 1 { progress?(1) }
        }
    }

    /// The disk has no room left: Foundation says it as `fileWriteOutOfSpace` (with `ENOSPC` underneath),
    /// a raw write as `ENOSPC`.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteOutOfSpaceError { return true }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOSPC) { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}
