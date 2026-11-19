// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AudioToolbox
import CoreAudio
import Foundation
import StelixCore

/// The tap on the default output plus the private aggregate that reads it, with a single IOProc.
///
/// The tap is on the stream of the output device that contains the macOS stereo pair
/// (`CATapDescription(excludingProcesses:deviceUID:stream:)`, `StereoRoute`), with the stream's native
/// channels: the global stereo tap does the mixdown and on cards with more than 2 channels it lowers the
/// volume (measured on a multichannel interface). The aggregate has the default output as main sub-device, so
/// input and output share a clock.
///
/// The aggregate's input also contains the sub-device's inputs (`kAudioSubDeviceInputChannelsKey = 0`
/// does not remove them): the tap sits in the **last** N channels. The IOProc takes the stereo
/// pair from the tap, calls `render` in stereo, then writes the output on the same pair of the device.
final class SystemTap {
    enum Mute { case mutedWhenTapped, unmuted }

    struct Format: Equatable {
        let sampleRate: Double
        /// Channels passed to `render` as `input`: always 2, the stereo pair taken from the tap.
        let inputChannels: Int
        /// Channels of `output` in `render`: always 2, written on the device's stereo pair.
        let outputChannels: Int
        /// Native channels of the tap (the whole stream).
        let tapChannels: Int
        let route: StereoRoute
        let isBluetooth: Bool
    }

    /// What, if it changes, forces a rebuild: default device, nominal rate, output
    /// channels per stream, macOS stereo pair.
    struct OutputSignature: Equatable {
        let device: AudioObjectID
        let sampleRate: Double
        let streamChannels: [Int]
        let stereo: [UInt32]

        static func current() -> OutputSignature {
            let device = CoreAudioProperty.defaultOutputDevice()
            let stereo = CoreAudioProperty.preferredStereo(device)
            return OutputSignature(device: device, sampleRate: CoreAudioProperty.nominalRate(device),
                                   streamChannels: CoreAudioProperty.streamChannels(device, scope: kAudioObjectPropertyScopeOutput),
                                   stereo: stereo.map { [$0.left, $0.right] } ?? [])
        }

        var preferredStereo: (left: UInt32, right: UInt32)? {
            stereo.count == 2 ? (stereo[0], stereo[1]) : nil
        }
    }

    typealias Render = @Sendable (_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>?, _ frames: Int) -> Void

    let format: Format
    /// The output as it was when the tap was born.
    let signature: OutputSignature
    let outputUID: String
    let outputName: String

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var scratch: IOScratch?

    /// Creates tap and aggregate, but starts nothing.
    init(mute: Mute) throws(EngineFailure) {
        signature = OutputSignature.current()
        let output = signature.device
        guard output != AudioObjectID(kAudioObjectUnknown),
              let uid = CoreAudioProperty.string(output, kAudioDevicePropertyDeviceUID) else {
            throw EngineFailure(.noOutput)
        }
        outputUID = uid
        outputName = CoreAudioProperty.string(output, kAudioObjectPropertyName) ?? ""
        // A device that is disappearing can give rate 0 or no channels: better noOutput (and a
        // new attempt) than a ring of 0 frames.
        guard signature.sampleRate > 0,
              var route = StereoRoute(streamChannels: signature.streamChannels, preferredStereo: signature.preferredStereo) else {
            throw EngineFailure(.noOutput)
        }

        // Without excluding itself the tap would pick up the engine's output again: an echo that grows every turn.
        let own = CoreAudioProperty.processObject(for: getpid())
        guard own != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineFailure(.tap)
        }
        let description = CATapDescription(excludingProcesses: [own], deviceUID: uid, stream: UInt(route.stream))
        description.name = "Stelix"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = mute == .mutedWhenTapped ? .mutedWhenTapped : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineFailure(.tap)
        }
        tap = tapID
        let (formatStatus, tapFormat) = CoreAudioProperty.value(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        let tapChannels = Int(tapFormat.mChannelsPerFrame)
        guard formatStatus == noErr, tapChannels > 0,
              tapFormat.mFormatID == kAudioFormatLinearPCM, tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw EngineFailure(.tap)
        }
        if max(route.tapLeft, route.tapRight) >= tapChannels {
            // The tap has fewer channels than the stream: stay on its first two.
            let start = route.outLeft - route.tapLeft, right = min(1, tapChannels - 1)
            route = StereoRoute(stream: route.stream, tapLeft: 0, tapRight: right, outLeft: start, outRight: start + right)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stelix",
            kAudioAggregateDeviceUIDKey: "io.github.stelix-app.stelix.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceInputChannelsKey: 0] as [String: Any]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID) == noErr,
              aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tapID)
            tap = AudioObjectID(kAudioObjectUnknown)
            throw EngineFailure(.outputSetup)
        }
        aggregate = aggregateID

        let rate = CoreAudioProperty.nominalRate(aggregateID)
        let transport = CoreAudioProperty.value(output, kAudioDevicePropertyTransportType, UInt32(0)).1
        format = Format(
            sampleRate: rate > 0 ? rate : signature.sampleRate,
            inputChannels: 2,
            outputChannels: 2,
            tapChannels: tapChannels,
            route: route,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    /// "pair 3-4 on stream 0 (4 channels)", for the logs.
    var routeDescription: String {
        let r = format.route
        return "pair \(r.outLeft + 1)-\(r.outRight + 1) on stream \(r.stream) (\(format.tapChannels) channels)"
    }

    deinit {
        destroy()
    }

    /// Registers the IOProc and starts the aggregate. `render` runs on the I/O thread: no locks,
    /// allocations, logs. `input` has `format.inputChannels` interleaved channels; `output` has
    /// `format.outputChannels` and is nil if the device has no outputs in this callback.
    ///
    /// With `output: false` (Studio recording) the IOProc also turns off its output streams:
    /// `render` receives `output` nil and the aggregate plays nothing.
    func start(output: Bool = true, render: @escaping Render) throws(EngineFailure) {
        guard procID == nil, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineFailure(.audioStart)
        }
        let bufferFrames = Int(CoreAudioProperty.value(aggregate, kAudioDevicePropertyBufferFrameSize, UInt32(512)).1)
        let scratch = IOScratch(route: format.route, tapChannels: format.tapChannels,
                                maxFrames: max(4096, bufferFrames * 2))
        self.scratch = scratch
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, makeIOBlock(scratch, render))
        guard status == noErr, let proc else {
            throw EngineFailure(.audioStart)
        }
        procID = proc
        // STELIX_KEEP_DEVICE_INPUTS=1 leaves the device inputs on: only for
        // comparison in testing, if turning them off caused problems on a card.
        if ProcessInfo.processInfo.environment["STELIX_KEEP_DEVICE_INPUTS"] != "1" { disableDeviceInputs(proc) }
        if !output { disableOutputs(proc) }
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            procID = nil
            throw EngineFailure(.audioStart)
        }
        running = true
    }

    /// Turns off, for this IOProc, the input streams of the output device and leaves on only
    /// those of the tap, at the end. `kAudioSubDeviceInputChannelsKey = 0` is not enough, and an
    /// open input brings AirPods into HFP. Turned-off streams arrive with `mData` nil: `gather`
    /// skips them but counts their channels, so the tap stays in the last N.
    private func disableDeviceInputs(_ proc: AudioDeviceIOProcID) {
        var addr = CoreAudioProperty.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &addr, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, raw) == noErr else { return }

        let count = Int(usage.pointee.mNumberStreams)
        let streams = CoreAudioProperty.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        guard count == streams.count, count > 1,
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let flags = (raw + offset).assumingMemoryBound(to: UInt32.self)
        // From the end: streams are kept on as long as they cover the tap's channels.
        var covered = 0
        for i in stride(from: count - 1, through: 0, by: -1) {
            let channels = Int(CoreAudioProperty.value(streams[i], kAudioStreamPropertyVirtualFormat,
                                                       AudioStreamBasicDescription()).1.mChannelsPerFrame)
            flags[i] = covered < format.tapChannels ? 1 : 0
            covered += channels
        }
        let status = AudioObjectSetPropertyData(aggregate, &addr, 0, nil, size, raw)
        let on = (0..<count).filter { flags[$0] != 0 }.count
        engineLog("tap: input streams turned on \(on) of \(count)\(status == noErr ? "" : " (error \(status))")")
    }

    /// Turns off, for this IOProc, all the aggregate's output streams. If it fails, the output
    /// stays on but receives only zeros (`render` receives `output` nil and the IOProc zeroes the buffers).
    private func disableOutputs(_ proc: AudioDeviceIOProcID) {
        var addr = CoreAudioProperty.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &addr, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size,
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, raw) == noErr else { return }
        let count = Int(usage.pointee.mNumberStreams)
        let flags = (raw + offset).assumingMemoryBound(to: UInt32.self)
        for i in 0..<count { flags[i] = 0 }
        let status = AudioObjectSetPropertyData(aggregate, &addr, 0, nil, size, raw)
        engineLog("tap: output streams turned off \(count)\(status == noErr ? "" : " (error \(status))")")
    }

    /// `AudioDeviceStop`: the IOProc no longer runs and, with the `.mutedWhenTapped` tap, the original returns.
    func stop() {
        guard running, let procID else { return }
        AudioDeviceStop(aggregate, procID)
        running = false
    }

    /// IOProc, then aggregate, then tap. It can be called several times.
    func destroy() {
        stop()
        if let procID {
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// MARK: - IOProc

/// Preallocated interleaved stereo buffers for the IOProc: written only from there.
private final class IOScratch: @unchecked Sendable {
    let route: StereoRoute
    let tapChannels: Int
    let maxFrames: Int
    let input: UnsafeMutablePointer<Float>
    let output: UnsafeMutablePointer<Float>

    init(route: StereoRoute, tapChannels: Int, maxFrames: Int) {
        self.route = route
        self.tapChannels = tapChannels
        self.maxFrames = maxFrames
        input = .allocate(capacity: 2 * maxFrames)
        input.initialize(repeating: 0, count: 2 * maxFrames)
        output = .allocate(capacity: 2 * maxFrames)
        output.initialize(repeating: 0, count: 2 * maxFrames)
    }

    deinit {
        input.deallocate()
        output.deallocate()
    }
}

/// Born in a nonisolated context, so Swift 6 does not attach to the block isolation checks that
/// would trip on the I/O thread. Blocks longer than `maxFrames` are done in pieces.
private nonisolated func makeIOBlock(_ scratch: IOScratch, _ render: @escaping SystemTap.Render) -> AudioDeviceIOBlock {
    return { _, inInputData, _, outOutputData, _ in
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let output = UnsafeMutableAudioBufferListPointer(outOutputData)

        var frames = 0
        for buffer in input where buffer.mNumberChannels > 0 {
            frames = max(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }
        var outChannels = 0
        var outFrames = 0
        for buffer in output where buffer.mNumberChannels > 0 {
            outChannels += Int(buffer.mNumberChannels)
            outFrames = max(outFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }
        if frames == 0 { frames = outFrames }
        guard frames > 0 else { return }
        // Even if the output has more or fewer channels than when the tap was born, it plays: `scatter` falls back
        // to the first two channels instead of leaving zeros for the whole session.
        let hasOutput = outChannels > 0

        var done = 0
        while done < frames {
            let n = min(frames - done, scratch.maxFrames)
            scratch.route.gather(input, tapChannels: scratch.tapChannels, offset: done, frames: n, into: scratch.input)
            render(scratch.input, hasOutput ? scratch.output : nil, n)
            if hasOutput { scratch.route.scatter(scratch.output, offset: done, frames: n, into: output) }
            done += n
        }
        if !hasOutput {
            for buffer in output { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        }
    }
}

// MARK: - Helper Core Audio

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> (OSStatus, T) {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return (status, value)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func defaultOutputDevice() -> AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
              AudioObjectID(kAudioObjectUnknown)).1
    }

    static func nominalRate(_ device: AudioObjectID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, Float64(0)).1
    }

    static func processObject(for pid: pid_t) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    /// The channels of each stream of the device in the given scope, in order.
    static func streamChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    /// Whether some process does IO on the device. With the Mac silent it is false, and the tap gives no callbacks.
    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(1)).1 != 0
    }

    /// The macOS stereo pair on the output (Configure Speakers), counted from 1.
    static func preferredStereo(_ device: AudioObjectID) -> (left: UInt32, right: UInt32)? {
        var addr = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var pair: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &pair) == noErr else { return nil }
        return (pair.0, pair.1)
    }

    /// The streams of the device in the given scope.
    static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
