// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AudioToolbox
import AVFoundation

/// The Studio player's nodes and connections, apart from its clock, fades and outputs (`StudioPlayer`
/// in the engine), so they can be rendered offline in the tests.
///
/// At 0 semitones every stem goes to the main mixer, as in 1.0.0. Transposed: every stem but the drums
/// → `restMixer` → `AVAudioUnitTimePitch` (AUNewTimePitch, the Live's algorithm) → `sumMixer`; the drums →
/// `sumMixer` directly, never transposed; then Apple's peak limiter, since the transposed sum can peak
/// above the original, and the main mixer. Playing in real time the time pitch delays the stems through it
/// by its latency, about 4096 frames, as in the Live: the drums start that much later (`play(at:)`).
/// Offline, in manual rendering, it pulls its input ahead instead and hides the delay: the tests render in
/// real-time mode.
public final class StudioGraph {
    public let engine: AVAudioEngine
    public let nodes: [Stem: AVAudioPlayerNode]
    public let lengthFrames: AVAudioFramePosition
    public let sampleRate: Double
    public private(set) var transpose: Transpose = .off

    private let files: [Stem: AVAudioFile]
    private let restMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let sumMixer = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

    /// Attaches a player node per stem file and connects them for 0 semitones.
    public init(engine: AVAudioEngine, files: [Stem: AVAudioFile]) throws(EngineFailure) {
        self.engine = engine
        self.files = files
        var nodes: [Stem: AVAudioPlayerNode] = [:]
        var length: AVAudioFramePosition = .max
        var rate = 44_100.0
        for stem in Stem.studio {
            guard let file = files[stem] else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            nodes[stem] = node
            length = min(length, file.length)
            rate = file.processingFormat.sampleRate
        }
        guard !nodes.isEmpty, length > 0, length != .max else { throw EngineFailure(.noStems) }
        self.nodes = nodes
        lengthFrames = length
        sampleRate = rate
        for node in [restMixer, timePitch, sumMixer, limiter] as [AVAudioNode] { engine.attach(node) }
        connect()
    }

    /// Only when crossing 0 the graph is rewired, and then the engine must be stopped; otherwise only the
    /// pitch changes, playing.
    public func setTranspose(_ value: Transpose) {
        let rewire = value.isOff != transpose.isOff
        transpose = value
        timePitch.pitch = Float(value.semitones * 100)
        if rewire { connect() }
    }

    /// From a sound in the stems to it in the output, past the clock node: the limiter's lookahead, after
    /// the sum; 0 at 0 semitones.
    public var latencyFrames: Int {
        transpose.isOff ? 0 : Self.latencyFrames(of: limiter.audioUnit, rate: sampleRate)
    }

    /// How much later than the others the drums start: the time pitch's latency, so they reach the sum
    /// with the transposed stems; 0 at 0 semitones.
    public var drumsDelayFrames: Int {
        transpose.isOff ? 0 : Self.latencyFrames(of: timePitch.audioUnit, rate: sampleRate)
    }

    /// Starts every node at `time`, the drums `drumsDelayFrames` later.
    public func play(at time: AVAudioTime) {
        let drums = time.offset(by: Double(drumsDelayFrames) / sampleRate)
        for (stem, node) in nodes { node.play(at: stem == .drums ? drums : time) }
    }

    /// Stops the nodes, empties the time pitch and the limiter (no sound from before), schedules every stem
    /// from `frame` to the end.
    public func schedule(from frame: AVAudioFramePosition) {
        for node in nodes.values { node.stop() }
        timePitch.reset()
        limiter.reset()
        let start = min(max(0, frame), lengthFrames)
        let count = AVAudioFrameCount(lengthFrames - start)
        guard count > 0 else { return }
        for (stem, node) in nodes {
            guard let file = files[stem] else { continue }
            node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil)
        }
    }

    /// The node whose time gives the position: the drums, which never go through the time pitch and start
    /// as late as it delays the rest; any node at 0 semitones.
    public var clockNode: AVAudioPlayerNode {
        nodes[.drums] ?? nodes.values.first!
    }

    // MARK: - Support

    private func connect() {
        for node in nodes.values { engine.disconnectNodeOutput(node) }
        for node in [restMixer, timePitch, sumMixer, limiter] as [AVAudioNode] { engine.disconnectNodeOutput(node) }
        let main = engine.mainMixerNode
        guard !transpose.isOff, let format = files.values.first?.processingFormat else {
            for (stem, node) in nodes { engine.connect(node, to: main, format: files[stem]?.processingFormat) }
            return
        }
        for (stem, node) in nodes {
            engine.connect(node, to: stem == .drums ? sumMixer : restMixer, format: files[stem]?.processingFormat)
        }
        engine.connect(restMixer, to: timePitch, format: format)
        engine.connect(timePitch, to: sumMixer, format: format)
        engine.connect(sumMixer, to: limiter, format: format)
        engine.connect(limiter, to: main, format: format)
    }

    private static func latencyFrames(of unit: AudioUnit, rate: Double) -> Int {
        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size) == noErr
        else { return 0 }
        return Int((latency * rate).rounded())
    }
}

private extension AVAudioTime {
    /// The same instant `seconds` later, on the host clock if the time has it, otherwise in samples.
    func offset(by seconds: Double) -> AVAudioTime {
        guard seconds != 0 else { return self }
        if isHostTimeValid { return AVAudioTime(hostTime: hostTime + AVAudioTime.hostTime(forSeconds: seconds)) }
        return AVAudioTime(sampleTime: sampleTime + AVAudioFramePosition((seconds * sampleRate).rounded()), atRate: sampleRate)
    }
}
