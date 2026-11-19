// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import StelixCore

/// Test files are created here, in a temporary folder: no audio in git.
struct AudioFileLoaderTests {
    private struct Fixture {
        let dir: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "AudioFileLoaderTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }

        /// Float32 WAV with `channels` channels. `fill(channel, frame)` gives the sample.
        func wav(_ name: String, rate: Double, channels: Int, seconds: Double,
                 layout: AudioChannelLayoutTag? = nil,
                 fill: (Int, Int) -> Float) throws -> URL {
            let url = dir.appending(path: name)
            let format: AVAudioFormat
            if let layout {
                format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: AVAudioChannelLayout(layoutTag: layout)!)
            } else {
                format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
            }
            let frames = Int((seconds * rate).rounded())
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for c in 0..<channels {
                for f in 0..<frames { buffer.floatChannelData![c][f] = fill(c, f) }
            }
            var settings = format.settings
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return url
        }

        /// A .mov with a 64×64 H.264 video track and a stereo AAC track with a 440 Hz sine.
        func movie(_ name: String, seconds: Double) throws -> URL {
            let url = dir.appending(path: name)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ])
            writer.add(video)
            writer.add(audio)
            #expect(writer.startWriting())
            writer.startSession(atSourceTime: .zero)

            let rate = 44_100.0
            let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)!
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: pcm.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            let chunk = 4_410
            let totalFrames = Int(seconds * rate)
            var written = 0
            var videoFrame = 0
            let videoFrames = Int(seconds * 10)

            func waitReady(_ input: AVAssetWriterInput) {
                let deadline = Date().addingTimeInterval(5)
                while !input.isReadyForMoreMediaData && Date() < deadline { usleep(1_000) }
            }

            while written < totalFrames || videoFrame < videoFrames {
                if videoFrame < videoFrames, Double(videoFrame) / 10 <= Double(written) / rate {
                    var pixels: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
                    waitReady(video)
                    adaptor.append(pixels!, withPresentationTime: CMTime(value: CMTimeValue(videoFrame), timescale: 10))
                    videoFrame += 1
                    continue
                }
                let frames = min(chunk, totalFrames - written)
                let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                let samples = buffer.floatChannelData![0]
                for f in 0..<frames {
                    let value = Float(0.5 * sin(2 * .pi * 440 * Double(written + f) / rate))
                    samples[2 * f] = value
                    samples[2 * f + 1] = value
                }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
                                                decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                     formatDescription: description, sampleCount: CMItemCount(frames),
                                     sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                     sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
                CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                               flags: 0, bufferList: buffer.audioBufferList)
                waitReady(audio)
                audio.append(sample!)
                written += frames
            }
            video.markAsFinished()
            audio.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            #expect(writer.status == .completed, "\(String(describing: writer.error))")
            return url
        }
    }

    private static func sine(_ frame: Int, rate: Double) -> Float {
        Float(0.5 * sin(2 * .pi * 440 * Double(frame) / rate))
    }

    /// The loader waits for AVAsset's async APIs with a semaphore: it must be called from a GCD queue, as
    /// the engine does, never from a cooperative-pool thread (where tests run).
    private static func load(_ url: URL, maxSeconds: Double = AudioFileLoader.defaultMaxSeconds)
        async throws(EngineFailure) -> (planarStereo: [Float], frames: Int) {
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<(planarStereo: [Float], frames: Int), EngineFailure>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: Result { () throws(EngineFailure) in try AudioFileLoader.load(url, maxSeconds: maxSeconds) })
            }
        }
        return try result.get()
    }

    @Test func loadsWav48kResampledTo44k() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.wav("a.wav", rate: 48_000, channels: 2, seconds: 1) { _, f in Self.sine(f, rate: 48_000) }
        let loaded = try await Self.load(url)
        #expect(abs(loaded.frames - 44_100) <= 1)
        #expect(loaded.planarStereo.count == 2 * loaded.frames)
        #expect(loaded.planarStereo.map(abs).max()! > 0.4)
    }

    @Test func monoBecomesStereo() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.wav("mono.wav", rate: 44_100, channels: 1, seconds: 1) { _, f in Self.sine(f, rate: 44_100) }
        let loaded = try await Self.load(url)
        #expect(loaded.frames == 44_100, "frame \(loaded.frames)")
        let left = loaded.planarStereo[0..<loaded.frames]
        let right = loaded.planarStereo[loaded.frames...]
        #expect(Array(left) == Array(right))
        #expect(left.map(abs).max()! > 0.4)
    }

    @Test func surroundDownmixesToStereo() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        // MPEG 5.1 A: L R C LFE Ls Rs. Signal on the center only.
        let url = try fx.wav("surround.wav", rate: 44_100, channels: 6, seconds: 1, layout: kAudioChannelLayoutTag_MPEG_5_1_A) { c, f in
            c == 2 ? Self.sine(f, rate: 44_100) : 0
        }
        let loaded = try await Self.load(url)
        #expect(loaded.frames == 44_100, "frame \(loaded.frames)")
        let left = Array(loaded.planarStereo[0..<loaded.frames])
        let right = Array(loaded.planarStereo[loaded.frames...])
        #expect(left == right)
        let peak = left.map(abs).max()!
        // −3 dB: 0,5 × 0,7071.
        #expect(abs(peak - 0.3536) < 0.01, "peak \(peak)")
    }

    @Test func videoWithAudioTrackLoads() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.movie("clip.mov", seconds: 1)
        let loaded = try await Self.load(url)
        #expect(abs(loaded.frames - 44_100) <= 2_048, "frame \(loaded.frames)")
        #expect(loaded.planarStereo.map(abs).max()! > 0.3)
    }

    @Test func nonAudioFileThrowsUnsupported() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = fx.dir.appending(path: "documento.pdf")
        try Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8).write(to: url)
        await #expect(throws: EngineFailure(.unsupported)) {
            try await Self.load(url)
        }
    }

    // MARK: - Files built to be wrong

    /// A 16-bit PCM WAV written byte by byte: the header says what the test wants, true or not.
    private static func rawWav(channels: Int, rate: Int, claimedFrames: Int, realFrames: Int) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let block = channels * 2
        let claimed = UInt32(claimedFrames * block)
        var data = Data("RIFF".utf8) + le(36 + claimed) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(channels)) + le(UInt32(rate))
        data += le(UInt32(rate * block)) + le(UInt16(block)) + le(UInt16(16))
        data += Data("data".utf8) + le(claimed)
        for frame in 0..<realFrames {
            let sample = Int16(16_000 * sin(2 * Double.pi * 440 * Double(frame) / 44_100))
            for _ in 0..<channels { data += le(sample) }
        }
        return data
    }

    /// A download or a copy cut halfway: the header promises 2 s, the file holds 1 s. What is there
    /// loads, and nothing is read past the end.
    @Test func truncatedWavLoadsTheAudioThatIsThere() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = fx.dir.appending(path: "cut.wav")
        try Self.rawWav(channels: 2, rate: 44_100, claimedFrames: 88_200, realFrames: 44_100).write(to: url)
        let loaded = try await Self.load(url)
        #expect(loaded.frames == 44_100)
        #expect(loaded.planarStereo.count == 88_200)
        #expect(loaded.planarStereo.map(abs).max()! > 0.4)
    }

    @Test func wavWithHeaderAndNoAudioIsUnsupported() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = fx.dir.appending(path: "header.wav")
        try Self.rawWav(channels: 2, rate: 44_100, claimedFrames: 88_200, realFrames: 0).write(to: url)
        await #expect(throws: EngineFailure(.unsupported)) { try await Self.load(url) }
    }

    /// A text file with an audio extension: the name decides nothing.
    @Test func textNamedMp3IsUnsupported() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = fx.dir.appending(path: "song.mp3")
        try Data(String(repeating: "this is not an mp3\n", count: 2_000).utf8).write(to: url)
        await #expect(throws: EngineFailure(.unsupported)) { try await Self.load(url) }
    }

    /// A header with sample rate 0 gave an infinite duration, and the error said "longer than 20 minutes".
    @Test func zeroSampleRateIsUnsupportedNotTooLong() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = fx.dir.appending(path: "zero-rate.wav")
        try Self.rawWav(channels: 2, rate: 0, claimedFrames: 44_100, realFrames: 44_100).write(to: url)
        await #expect(throws: EngineFailure(.unsupported)) { try await Self.load(url) }
    }

    @Test func missingFileThrowsUnsupported() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "non-esiste-\(UUID().uuidString).wav")
        await #expect(throws: EngineFailure.self) { try await Self.load(url) }
    }

    @Test func veryShortFileLoads() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.wav("corto.wav", rate: 44_100, channels: 2, seconds: 0.5) { _, f in Self.sine(f, rate: 44_100) }
        let loaded = try await Self.load(url)
        #expect(loaded.frames == 22_050)
    }

    @Test func tooLongFileThrowsBeforeDecoding() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.wav("lungo.wav", rate: 44_100, channels: 2, seconds: 1) { _, f in Self.sine(f, rate: 44_100) }
        await #expect(throws: EngineFailure.self) { try await Self.load(url, maxSeconds: 0.5) }
        do {
            _ = try await Self.load(url, maxSeconds: 0.5)
        } catch {
            #expect(error.code == "tooLong")
        }
        // `detail` is the cap in minutes: the app writes the sentence.
        do {
            _ = try await Self.load(url, maxSeconds: 0.5)
        } catch {
            #expect(error == EngineFailure(.tooLong, detail: "0"))
        }
        let fits = try await Self.load(url, maxSeconds: 2)
        #expect(fits.frames == 44_100)
    }

    @Test func tooLongVideoThrows() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.movie("lungo.mov", seconds: 1)
        do {
            _ = try await Self.load(url, maxSeconds: 0.5)
            Issue.record("should have rejected the file")
        } catch {
            #expect(error.code == "tooLong")
        }
    }

    /// One channel at 1 and the others at 0, without labels: where it ends up in the downmix.
    private static func unlabeled(count: Int, hot: Int) -> (left: Float, right: Float) {
        let channels = (0..<count).map { [Float](repeating: $0 == hot ? 1 : 0, count: 4) }
        let stereo = AudioFileLoader.downmix(.init(channels: channels, sampleRate: 44_100, labels: nil))
        return (stereo[0], stereo[4])
    }

    @Test func unlabeledQuadKeepsTheRearPair() {
        let m3 = AudioFileLoader.minus3dB
        #expect(Self.unlabeled(count: 4, hot: 2) == (m3, 0))
        #expect(Self.unlabeled(count: 4, hot: 3) == (0, m3))
    }

    @Test func unlabeledThreeAndFiveChannelsHaveNoLFE() {
        let m3 = AudioFileLoader.minus3dB
        #expect(Self.unlabeled(count: 3, hot: 2) == (m3, m3))
        #expect(Self.unlabeled(count: 5, hot: 3) == (m3, 0))
        #expect(Self.unlabeled(count: 5, hot: 4) == (0, m3))
        // 5.1 without labels: the fourth is the LFE and stays out.
        #expect(Self.unlabeled(count: 6, hot: 3) == (0, 0))
    }

    @Test func defaultCapIsTwentyMinutes() {
        #expect(AudioFileLoader.defaultMaxSeconds == 20 * 60)
    }
}
