// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation

/// Sample-rate change of a planar stereo block (`[L0 … Ln-1, R0 … Rn-1]`).
/// The output has `round(n × to / from)` frames per channel, aligned with the input (no latency).
public protocol Resampling {
    func convert(planarStereo: [Float], from: Double, to: Double) -> [Float]
}

/// `AVAudioConverter` at `.max` quality (never linear interpolation).
/// One converter per call: the cost stays off the IOProc, on the ML thread.
public struct AVResampler: Resampling {
    public init() {}

    public func convert(planarStereo input: [Float], from: Double, to: Double) -> [Float] {
        let frames = input.count / 2
        guard from != to, frames > 0 else { return input }
        let expected = Int((Double(frames) * to / from).rounded())
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: from, channels: 2),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: to, channels: 2),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(expected + 256))
        else { return [Float](repeating: 0, count: 2 * expected) }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // `.normal`: no latency, frames before the start count as silence.
        converter.primeMethod = .normal

        inBuffer.frameLength = AVAudioFrameCount(frames)
        input.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: frames)
            inBuffer.floatChannelData![1].update(from: src.baseAddress! + frames, count: frames)
        }

        let feed = InputFeed(buffer: inBuffer)
        var output = [Float](repeating: 0, count: 2 * expected)
        var produced = 0
        while produced < expected {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, status in
                feed.next(status)
            }
            let got = min(Int(outBuffer.frameLength), expected - produced)
            if got > 0 {
                output.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + produced).update(from: outBuffer.floatChannelData![0], count: got)
                    (dst.baseAddress! + expected + produced).update(from: outBuffer.floatChannelData![1], count: got)
                }
                produced += got
            }
            if status == .endOfStream || status == .error || outBuffer.frameLength == 0 { break }
        }
        return output
    }
}

/// Hands over the input buffer once, then the end of the stream.
private final class InputFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var given = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if given {
            status.pointee = .endOfStream
            return nil
        }
        given = true
        status.pointee = .haveData
        return buffer
    }
}
