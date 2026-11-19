// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import CoreMedia

/// Loads a file dropped on Studio as planar stereo (`[L0 … Ln-1, R0 … Rn-1]`) at the requested
/// rate. Tries `AVAudioFile` first (WAV, AIFF, CAF, MP3, M4A), then `AVAssetReader` on the first
/// audio track (video, and everything else AVFoundation reads). Mono → two equal channels; more than
/// two channels → ITU downmix with center and surround at −3 dB and LFE excluded. The rate is changed
/// with `AVResampler` (never linear interpolation).
public enum AudioFileLoader {
    static let unsupported = EngineFailure(.unsupported)

    /// Beyond this duration the file is not even decoded: an hour of film would hold in memory
    /// about fifteen 1.3 GB copies between loader and separation.
    public static let defaultMaxSeconds: Double = 20 * 60

    public static func load(_ url: URL, sampleRate: Double = 44100,
                            maxSeconds: Double = defaultMaxSeconds) throws(EngineFailure) -> (planarStereo: [Float], frames: Int) {
        // `detail` is the cap in minutes: the app writes the sentence.
        let tooLong = EngineFailure(.tooLong, detail: String(Int(maxSeconds / 60)))
        let native: Native?
        if let file = try? AVAudioFile(forReading: url) {
            // A header with rate 0 would give an infinite duration, and the wrong error.
            guard file.processingFormat.sampleRate > 0 else { throw unsupported }
            guard Double(file.length) / file.processingFormat.sampleRate <= maxSeconds else { throw tooLong }
            native = read(file)
        } else {
            native = try readWithAssetReader(url, maxSeconds: maxSeconds, tooLong: tooLong)
        }
        guard let native, native.frames > 0 else { throw unsupported }
        let stereo = downmix(native)
        let converted = AVResampler().convert(planarStereo: stereo, from: native.sampleRate, to: sampleRate)
        return (converted, converted.count / 2)
    }

    /// The file as it is: one array per channel, plus the rate and the channel labels if the file has them.
    struct Native {
        var channels: [[Float]]
        var sampleRate: Double
        var labels: [AudioChannelLabel]?
        var frames: Int { channels.first?.count ?? 0 }
    }

    // MARK: - Reading

    private static func read(_ file: AVAudioFile) -> Native? {
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let chunkFrames = 65_536
        guard file.length > 0, channelCount > 0,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)),
              let data = chunk.floatChannelData
        else { return nil }
        // A single `read` can return fewer frames than requested (44,032 of 44,100 in a mono WAV):
        // read in blocks until the end.
        var channels = [[Float]](repeating: [], count: channelCount)
        for c in 0..<channelCount { channels[c].reserveCapacity(Int(file.length)) }
        while file.framePosition < file.length {
            guard (try? file.read(into: chunk, frameCount: AVAudioFrameCount(chunkFrames))) != nil else { return nil }
            let got = Int(chunk.frameLength)
            if got == 0 { break }
            for c in 0..<channelCount { channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: got)) }
        }
        let labels = format.channelLayout.flatMap { Self.labels(of: $0.layout, channels: channelCount) }
        return Native(channels: channels, sampleRate: format.sampleRate, labels: labels)
    }

    private static func readWithAssetReader(_ url: URL, maxSeconds: Double,
                                            tooLong: EngineFailure) throws(EngineFailure) -> Native? {
        let asset = AVURLAsset(url: url)
        guard let tracks = blocking({ try await asset.loadTracks(withMediaType: .audio) }), let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        if let duration = blocking({ try await asset.load(.duration) }), duration.seconds > maxSeconds {
            throw tooLong
        }
        // Without rate and channels in the settings, the output keeps those of the track.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var interleaved: [Float] = []
        var channelCount = 0
        var sampleRate = 0.0
        var labels: [AudioChannelLabel]?
        while let sample = output.copyNextSampleBuffer() {
            if channelCount == 0, let description = CMSampleBufferGetFormatDescription(sample),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                channelCount = Int(asbd.mChannelsPerFrame)
                sampleRate = asbd.mSampleRate
                var layoutSize = 0
                if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) {
                    labels = Self.labels(of: layout, channels: channelCount)
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let start = interleaved.count
            interleaved.append(contentsOf: repeatElement(0, count: bytes / MemoryLayout<Float>.size))
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        guard reader.status == .completed, channelCount > 0, sampleRate > 0 else { return nil }
        let frames = interleaved.count / channelCount
        let channels = (0..<channelCount).map { c in (0..<frames).map { interleaved[$0 * channelCount + c] } }
        return Native(channels: channels, sampleRate: sampleRate, labels: labels)
    }

    // MARK: - Downmix

    static let minus3dB: Float = 0.70710677

    /// The gain of one channel toward left and right.
    static func gains(label: AudioChannelLabel?, index: Int, count: Int) -> (left: Float, right: Float) {
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_LeftCenter: return (1, 0)
        case kAudioChannelLabel_Right, kAudioChannelLabel_RightCenter: return (0, 1)
        case kAudioChannelLabel_Center, kAudioChannelLabel_Mono, kAudioChannelLabel_CenterSurround:
            return (minus3dB, minus3dB)
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return (0, 0)
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RearSurroundLeft,
             kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_LeftWide:
            return (minus3dB, 0)
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundRight,
             kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RightWide:
            return (0, minus3dB)
        default:
            // When the file says nothing: L R, then it depends on the channel count. With 3 there is the
            // center, with 4 a quadraphonic (Ls Rs), with 5 a 5.0 (C Ls Rs). From 6 up the WAVE
            // order: L R C LFE, then surround pairs.
            switch (index, count) {
            case (0, _): return (1, 0)
            case (1, _): return (0, 1)
            case (2, 4): return (minus3dB, 0)
            case (3, 4): return (0, minus3dB)
            case (2, _): return (minus3dB, minus3dB)
            case (3, 5): return (minus3dB, 0)
            case (4, 5): return (0, minus3dB)
            case (3, _): return (0, 0)
            default: return index % 2 == 0 ? (minus3dB, 0) : (0, minus3dB)
            }
        }
    }

    static func downmix(_ native: Native) -> [Float] {
        let frames = native.frames
        switch native.channels.count {
        case 1: return native.channels[0] + native.channels[0]
        case 2: return native.channels[0] + native.channels[1]
        default:
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            for (index, channel) in native.channels.enumerated() {
                let label = native.labels.flatMap { index < $0.count ? $0[index] : nil }
                let known = label.map { $0 != kAudioChannelLabel_Unknown && $0 != kAudioChannelLabel_Unused } ?? false
                let gain = gains(label: known ? label : nil, index: index, count: native.channels.count)
                for f in 0..<frames {
                    left[f] += gain.left * channel[f]
                    right[f] += gain.right * channel[f]
                }
            }
            return left + right
        }
    }

    /// The channel labels of a layout, expanding tags and bitmaps with `AudioFormatGetProperty`.
    static func labels(of layout: UnsafePointer<AudioChannelLayout>, channels: Int) -> [AudioChannelLabel]? {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return descriptions(of: layout)
        }
        let property: AudioFormatPropertyID
        var specifier: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            property = kAudioFormatProperty_ChannelLayoutForBitmap
            specifier = layout.pointee.mChannelBitmap.rawValue
        } else {
            property = kAudioFormatProperty_ChannelLayoutForTag
            specifier = tag
        }
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, UInt32(MemoryLayout<UInt32>.size), &specifier, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
        let expanded = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { expanded.deallocate() }
        guard AudioFormatGetProperty(property, UInt32(MemoryLayout<UInt32>.size), &specifier, &size, expanded) == noErr else {
            return nil
        }
        let result = descriptions(of: expanded.assumingMemoryBound(to: AudioChannelLayout.self))
        return result?.count == channels ? result : nil
    }

    private static func descriptions(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0 else { return nil }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { first[$0].mChannelLabel }
    }

    // MARK: - Async → sync

    /// AVAsset APIs are async; the loader runs on an engine queue and can wait.
    private static func blocking<T>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await work()
            done.signal()
        }
        done.wait()
        return box.value
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
