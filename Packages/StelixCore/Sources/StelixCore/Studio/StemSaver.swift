// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

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
    public static func save(_ result: StemsResult, recording: URL?, sourceName: String?,
                            root: URL = StudioFolder.defaultRoot, date: Date,
                            names: (Stem) -> String, recordingName: String,
                            provenance: StemProvenance? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = try StudioFolder.make(root: root, date: date, sourceName: sourceName)
        do {
            for stem in Stem.studio {
                guard let path = result.files[stem] else { throw CocoaError(.fileNoSuchFile) }
                let saved = folder.appending(path: names(stem))
                try fm.copyItem(at: URL(fileURLWithPath: path), to: saved)
                if let provenance {
                    try WavInfo.append(software: provenance.software, comment: provenance.comment, to: saved)
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
