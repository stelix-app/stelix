// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AudioToolbox
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
///
/// At another speed (`FileTimeStretch`) the time pitch reads the file by itself, as much as it needs, and
/// the result is exactly `round(frames ÷ factor)` long; every stem goes through it, the drums with 0
/// semitones, so they all stay in time.
public enum StemTransposer {
    static let blockFrames = 4096

    /// `progress` gets the source frames read so far, ending with all of them.
    public static func transpose(_ source: URL, to destination: URL, semitones: Int, speed: Speed = .normal,
                                 cancel: SaveCancel?, progress: (Int) -> Void) throws {
        if cancel?.isCancelled == true { throw CancellationError() }
        guard speed.isNormal else {
            try FileTimeStretch.run(source, to: destination, semitones: semitones, speed: speed,
                                    cancel: cancel, progress: progress)
            return
        }
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

/// AUNewTimePitch at a rate other than 1, off real time: it asks for more or less input than it gives, so
/// its render callback reads the source file itself (zeros after the end). The first `latency` output frames
/// are dropped, the reported latency at that rate.
final class FileTimeStretch {
    private let unit: AudioUnit
    private let input: AVAudioFile
    private let readBuffer: AVAudioPCMBuffer
    private let total: AVAudioFramePosition
    private(set) var read: AVAudioFramePosition = 0
    private var readError: (any Error)?
    private let progress: (Int) -> Void

    static func run(_ source: URL, to destination: URL, semitones: Int, speed: Speed,
                    cancel: SaveCancel?, progress: (Int) -> Void) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.channelCount == 2, format.commonFormat == .pcmFormatFloat32 else { throw CocoaError(.fileReadCorruptFile) }
        let rate = format.sampleRate
        let output = try AVAudioFile(forWriting: destination, settings: StemFiles.wavSettings(sampleRate: rate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = StemTransposer.blockFrames
        guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))
        else { throw CocoaError(.fileWriteUnknown) }
        try withoutActuallyEscaping(progress) { progress in
            let stretch = try FileTimeStretch(input: input, semitones: semitones, speed: speed, progress: progress)
            let wanted = AVAudioFramePosition((Double(input.length) / speed.factor).rounded())
            var skip = stretch.latencyFrames(rate: rate)
            var written: AVAudioFramePosition = 0
            var time = AudioTimeStamp()
            time.mFlags = .sampleTimeValid
            while written < wanted {
                if cancel?.isCancelled == true { throw CancellationError() }
                writeBuffer.frameLength = AVAudioFrameCount(block)
                var flags = AudioUnitRenderActionFlags()
                let status = AudioUnitRender(stretch.unit, &flags, &time, 0, UInt32(block), writeBuffer.mutableAudioBufferList)
                time.mSampleTime += Double(block)
                if let error = stretch.readError { throw error }
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
                let dropped = min(skip, block)
                skip -= dropped
                let usable = min(block - dropped, Int(wanted - written))
                guard usable > 0 else { continue }
                if dropped > 0 {
                    for c in 0..<2 {
                        let data = writeBuffer.floatChannelData![c]
                        data.update(from: data + dropped, count: usable)
                    }
                }
                writeBuffer.frameLength = AVAudioFrameCount(usable)
                try output.write(from: writeBuffer)
                written += AVAudioFramePosition(usable)
            }
            output.close()
            progress(Int(input.length))
        }
    }

    private init(input: AVAudioFile, semitones: Int, speed: Speed, progress: @escaping (Int) -> Void) throws {
        self.input = input
        self.progress = progress
        total = input.length
        // The time pitch may ask for up to `factor` × a block, and some more: room for twice that.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: AVAudioFrameCount(StemTransposer.blockFrames * 4))
        else { throw CocoaError(.fileWriteUnknown) }
        readBuffer = buffer
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr, let instance
        else { throw EngineFailure(.outputSetup) }
        unit = instance
        var format = input.processingFormat.streamDescription.pointee
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxSlice = UInt32(StemTransposer.blockFrames)
        var callback = AURenderCallbackStruct(inputProc: fileTimeStretchInput,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let statuses = [
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize),
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize),
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, 4),
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            AudioUnitInitialize(unit),
            AudioUnitSetParameter(unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float(speed.factor), 0),
            AudioUnitSetParameter(unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, Float(semitones * 100), 0),
        ]
        guard statuses.allSatisfy({ $0 == noErr }) else {
            AudioComponentInstanceDispose(unit)
            throw EngineFailure(.outputSetup)
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// The reported latency at the rate set, in output frames.
    func latencyFrames(rate: Double) -> Int {
        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)
        return Int((latency * rate).rounded())
    }

    /// The time pitch's input: the next `frames` of the file, zeros past its end.
    fileprivate func pull(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        var filled = 0
        while filled < frames, read < total, readError == nil {
            let count = min(frames - filled, Int(readBuffer.frameCapacity), Int(total - read))
            do {
                try input.read(into: readBuffer, frameCount: AVAudioFrameCount(count))
            } catch {
                readError = error
                break
            }
            let got = Int(readBuffer.frameLength)
            guard got > 0 else {
                readError = CocoaError(.fileReadCorruptFile)
                break
            }
            (left + filled).update(from: readBuffer.floatChannelData![0], count: got)
            (right + filled).update(from: readBuffer.floatChannelData![1], count: got)
            filled += got
            read += AVAudioFramePosition(got)
            progress(Int(read))
        }
        for f in filled..<frames { left[f] = 0; right[f] = 0 }
    }
}

private let fileTimeStretchInput: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    Unmanaged<FileTimeStretch>.fromOpaque(refCon)._withUnsafeGuaranteedRef { $0.pull(frames: Int(frames), into: ioData) }
    return noErr
}
