// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation

/// Writes the stems of a separation into a Studio folder, with `Stem.fileName`.
///
/// Each stem goes first to `.<name>.partial`; only when all are written are they renamed over the
/// real names (`commit`: `rename(2)`, which replaces in one go and does not disturb whoever has already opened
/// the old file). A cancellation or an error deletes the temporaries and leaves the previous stems as they were,
/// all of them: never half new and half old.
public enum StemFiles {
    static let cancelled = EngineFailure(.separationCancelled)
    public static let writeFailed = EngineFailure(.stemsUnwritable)
    /// `.<name>.partial`: a stem being written. `.<name>.previous`: the old stem, while the new ones go in.
    public static let partialSuffix = ".partial"
    public static let previousSuffix = ".previous"

    /// Renames every temporary onto its real name, as a set. First each old file gets
    /// a hard link `.<name>.previous`; if a rename fails, the names already replaced go back to the
    /// old ones (or disappear, if they were not there before), the temporaries are deleted and `writeFailed` rises.
    /// `rename` is replaced only in tests.
    public static func commit(_ pairs: [(partial: URL, final: URL)],
                              rename: (String, String) -> Int32 = { Darwin.rename($0, $1) }) throws(EngineFailure) {
        let fm = FileManager.default
        var backups: [URL?] = []
        func cleanup() {
            for pair in pairs { try? fm.removeItem(at: pair.partial) }
            for backup in backups.compactMap({ $0 }) { try? fm.removeItem(at: backup) }
        }
        for pair in pairs {
            let backup = pair.final.deletingLastPathComponent().appending(path: ".\(pair.final.lastPathComponent)\(previousSuffix)")
            try? fm.removeItem(at: backup)
            if fm.fileExists(atPath: pair.final.path) {
                guard link(pair.final.path, backup.path) == 0 else {
                    cleanup()
                    throw writeFailed
                }
                backups.append(backup)
            } else {
                backups.append(nil)
            }
        }
        for (index, pair) in pairs.enumerated() where rename(pair.partial.path, pair.final.path) != 0 {
            for (done, previous) in zip(pairs[..<index], backups[..<index]) {
                if let previous {
                    _ = rename(previous.path, done.final.path)
                } else {
                    try? fm.removeItem(at: done.final)
                }
            }
            cleanup()
            throw writeFailed
        }
        cleanup()
    }

    /// `stems` are planar stereo of `frames` frames at `sampleRate`. `isCancelled` is checked
    /// before each file.
    public static func write(_ stems: [(Stem, [Float])], frames: Int, sampleRate: Double = 44_100, into folder: URL,
                             isCancelled: () -> Bool) throws(EngineFailure) -> [Stem: URL] {
        var partials: [(partial: URL, final: URL, stem: Stem)] = []
        func discard() { for item in partials { try? FileManager.default.removeItem(at: item.partial) } }

        for (stem, samples) in stems {
            if isCancelled() {
                discard()
                throw cancelled
            }
            let final = folder.appending(path: stem.fileName)
            let partial = folder.appending(path: ".\(stem.fileName)\(partialSuffix)")
            partials.append((partial, final, stem))
            do throws(EngineFailure) {
                try writeWAV(samples, frames: frames, sampleRate: sampleRate, to: partial)
            } catch {
                discard()
                throw error
            }
        }
        if isCancelled() {
            discard()
            throw cancelled
        }
        try commit(partials.map { ($0.partial, $0.final) })
        return Dictionary(uniqueKeysWithValues: partials.map { ($0.stem, $0.final) })
    }

    /// The stems' file format: stereo Float32 WAV. The file type is stated, not left to the extension.
    public static func wavSettings(sampleRate: Double) -> [String: Any] {
        [AVAudioFileTypeKey: kAudioFileWAVEType,
         AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
         AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    }

    /// Stereo Float32 WAV, closed before returning (header with the right length). The file type is
    /// stated, not left to the extension: `write` writes to `.<name>.partial`, which AVAudioFile turns into a CAF.
    public static func writeWAV(_ planarStereo: [Float], frames: Int, sampleRate: Double, to url: URL) throws(EngineFailure) {
        guard planarStereo.count >= 2 * frames,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: wavSettings(sampleRate: sampleRate),
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))
        else { throw writeFailed }
        buffer.frameLength = AVAudioFrameCount(frames)
        planarStereo.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: frames)
            buffer.floatChannelData![1].update(from: src.baseAddress! + frames, count: frames)
        }
        do { try file.write(from: buffer) } catch { throw writeFailed }
        file.close()
    }
}
