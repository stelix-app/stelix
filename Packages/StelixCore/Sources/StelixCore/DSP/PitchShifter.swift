// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AudioToolbox

/// Changes the pitch of a stereo interleaved signal, keeping its tempo. `process` and `setSemitones`
/// run on the audio thread: no allocation, no lock. At most `TransposeChain.maxFrames` frames per call.
public protocol PitchShifter: AnyObject {
    /// Frames between a sound going in and coming out.
    var latencyFrames: Int { get }
    func setSemitones(_ semitones: Int)
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int)
}

/// Apple's AUNewTimePitch (format converter, rate 1), part of macOS: chosen on 25/11 against Signalsmith
/// Stretch. It pulls its input from a render callback in blocks as long as the ones given to `process`
/// (measured on 25/11: no FIFO needed), so the callback reads the block being processed.
public final class AppleTimePitch: PitchShifter, @unchecked Sendable {
    public private(set) var latencyFrames = 0
    private let unit: AudioUnit
    private let maxFrames: Int
    private let inLeft: UnsafeMutablePointer<Float>
    private let inRight: UnsafeMutablePointer<Float>
    private let outLeft: UnsafeMutablePointer<Float>
    private let outRight: UnsafeMutablePointer<Float>
    private let outList: UnsafeMutableAudioBufferListPointer
    /// Frames of the current block, and how many of them the AU has already pulled.
    private var available = 0
    private var pulled = 0
    private var time = AudioTimeStamp()

    public init(sampleRate: Double, maxFrames: Int = TransposeChain.maxFrames) throws(EngineFailure) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr, let instance
        else { throw EngineFailure(.outputSetup) }
        unit = instance
        self.maxFrames = maxFrames
        inLeft = .allocate(capacity: maxFrames)
        inRight = .allocate(capacity: maxFrames)
        outLeft = .allocate(capacity: maxFrames)
        outRight = .allocate(capacity: maxFrames)
        for buffer in [inLeft, inRight, outLeft, outRight] { buffer.initialize(repeating: 0, count: maxFrames) }
        outList = AudioBufferList.allocate(maximumBuffers: 2)

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxSlice = UInt32(maxFrames)
        var callback = AURenderCallbackStruct(inputProc: appleTimePitchInput, inputProcRefCon: nil)
        callback.inputProcRefCon = Unmanaged.passUnretained(self).toOpaque()
        let statuses = [
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize),
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize),
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, 4),
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            AudioUnitInitialize(unit),
            AudioUnitSetParameter(unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, 1, 0),
        ]
        guard statuses.allSatisfy({ $0 == noErr }) else { throw EngineFailure(.outputSetup) }
        var latency: Float64 = 0
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &latencySize)
        latencyFrames = Int((latency * sampleRate).rounded())
        time.mFlags = .sampleTimeValid
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        free(outList.unsafeMutablePointer)
        for buffer in [inLeft, inRight, outLeft, outRight] { buffer.deallocate() }
    }

    /// Semitones × 100 cents.
    public func setSemitones(_ semitones: Int) {
        AudioUnitSetParameter(unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, Float(semitones * 100), 0)
    }

    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
        let frames = min(frames, maxFrames)
        for f in 0..<frames {
            inLeft[f] = input[f * 2]
            inRight[f] = input[f * 2 + 1]
        }
        available = frames
        pulled = 0
        let bytes = UInt32(frames * 4)
        outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: outLeft)
        outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: outRight)
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), outList.unsafeMutablePointer)
        time.mSampleTime += Double(frames)
        guard status == noErr else {
            for i in 0..<frames * 2 { output[i] = 0 }
            return
        }
        let left = outList[0].mData!.assumingMemoryBound(to: Float.self)
        let right = outList[1].mData!.assumingMemoryBound(to: Float.self)
        for f in 0..<frames {
            output[f * 2] = left[f]
            output[f * 2 + 1] = right[f]
        }
    }

    /// The AU's input: the block being processed; zeros if it asks for more than there is.
    fileprivate func pull(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let have = min(frames, available - pulled)
        left.update(from: inLeft + pulled, count: have)
        right.update(from: inRight + pulled, count: have)
        for f in have..<frames { left[f] = 0; right[f] = 0 }
        pulled += have
    }
}

private let appleTimePitchInput: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    // No retain on the audio thread: the shifter outlives every render it is part of.
    Unmanaged<AppleTimePitch>.fromOpaque(refCon)._withUnsafeGuaranteedRef { $0.pull(frames: Int(frames), into: ioData) }
    return noErr
}
