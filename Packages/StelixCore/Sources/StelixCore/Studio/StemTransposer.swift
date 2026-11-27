// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import Synchronization

/// Stops a transposed save: set from any thread, checked between blocks. A child stops with its parent.
public final class SaveCancel: Sendable {
    private let flag = Atomic<Bool>(false)
    private let parent: SaveCancel?

    public init() { parent = nil }
    init(parent: SaveCancel?) { self.parent = parent }

    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) || parent?.isCancelled == true }
}

/// A stem file through the same time pitch as the Live (`AppleTimePitch`), off real time. The first
/// `latencyFrames` of the output are dropped and zeros fed at the end, so the result is exactly as long as
/// the source and stays in time with the drums, which are copied as they are. Stereo Float32 WAV, like the
/// stems: a transposed peak above 0 dBFS is kept, not clipped.
public enum StemTransposer {
    static let blockFrames = 4096

    /// `progress` gets the source frames read so far, ending with all of them.
    public static func transpose(_ source: URL, to destination: URL, semitones: Int,
                                 cancel: SaveCancel?, progress: (Int) -> Void) throws {
        if cancel?.isCancelled == true { throw CancellationError() }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.channelCount == 2, format.commonFormat == .pcmFormatFloat32 else { throw CocoaError(.fileReadCorruptFile) }
        let rate = format.sampleRate
        let shifter = try AppleTimePitch(sampleRate: rate, maxFrames: blockFrames)
        shifter.setSemitones(semitones)
        let output = try AVAudioFile(forWriting: destination, settings: StemFiles.wavSettings(sampleRate: rate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockFrames)),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockFrames))
        else { throw CocoaError(.fileWriteUnknown) }

        let total = input.length
        var interleavedIn = [Float](repeating: 0, count: blockFrames * 2)
        var interleavedOut = [Float](repeating: 0, count: blockFrames * 2)
        var read: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        var skip = shifter.latencyFrames
        while written < total {
            if cancel?.isCancelled == true { throw CancellationError() }
            let frames: Int
            if read < total {
                try input.read(into: readBuffer, frameCount: AVAudioFrameCount(min(Int64(blockFrames), total - read)))
                frames = Int(readBuffer.frameLength)
                guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let l = readBuffer.floatChannelData![0], r = readBuffer.floatChannelData![1]
                for f in 0..<frames {
                    interleavedIn[f * 2] = l[f]
                    interleavedIn[f * 2 + 1] = r[f]
                }
                read += AVAudioFramePosition(frames)
                progress(Int(read))
            } else {
                // The source is over: zeros push its last latency out of the time pitch.
                frames = blockFrames
                for i in 0..<(frames * 2) { interleavedIn[i] = 0 }
            }
            interleavedIn.withUnsafeBufferPointer { src in
                interleavedOut.withUnsafeMutableBufferPointer { dst in
                    shifter.process(src.baseAddress!, dst.baseAddress!, frames: frames)
                }
            }
            let dropped = min(skip, frames)
            skip -= dropped
            let usable = min(frames - dropped, Int(total - written))
            guard usable > 0 else { continue }
            let l = writeBuffer.floatChannelData![0], r = writeBuffer.floatChannelData![1]
            for f in 0..<usable {
                l[f] = interleavedOut[(dropped + f) * 2]
                r[f] = interleavedOut[(dropped + f) * 2 + 1]
            }
            writeBuffer.frameLength = AVAudioFrameCount(usable)
            try output.write(from: writeBuffer)
            written += AVAudioFramePosition(usable)
        }
        output.close()
        if total == 0 { progress(0) }
    }
}
