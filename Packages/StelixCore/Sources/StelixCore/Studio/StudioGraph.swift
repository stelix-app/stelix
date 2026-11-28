// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AudioToolbox
import AVFoundation

/// The Studio player's nodes and connections, apart from its clock, fades and outputs (`StudioPlayer`
/// in the engine), so they can be rendered offline in the tests.
///
/// Three shapes (`Shape`):
/// - off, 0 semitones at 100%: every stem goes to the main mixer, as in 1.0.0;
/// - transposed at 100%: every stem but the drums → `restMixer` → `AVAudioUnitTimePitch` (AUNewTimePitch,
///   the Live's algorithm) → `sumMixer`; the drums → `sumMixer` directly, never transposed; then Apple's
///   peak limiter, since the transposed sum can peak above the original, and the main mixer. Playing in
///   real time the time pitch delays the stems through it by its latency, about 4096 frames, as in the
///   Live: the drums start that much later (`play(at:)`);
/// - stretched, any other speed: the same, but the drums go through a time pitch of their own, `drumsPitch`,
///   with the same rate and no pitch: the two have the same latency, so the drums start with the rest.
///
/// Offline, in manual rendering, the time pitch pulls its input ahead instead and hides the delay: the tests
/// render in real-time mode.
public final class StudioGraph {
    public enum Shape: Sendable, Equatable {
        case off, transposed, stretched

        public init(transpose: Transpose, speed: Speed) {
            self = !speed.isNormal ? .stretched : transpose.isOff ? .off : .transposed
        }
    }

    public let engine: AVAudioEngine
    public let nodes: [Stem: AVAudioPlayerNode]
    public let lengthFrames: AVAudioFramePosition
    public let sampleRate: Double
    public private(set) var transpose: Transpose = .off
    public private(set) var speed: Speed = .normal
    public var shape: Shape { Shape(transpose: transpose, speed: speed) }

    private let files: [Stem: AVAudioFile]
    private let restMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let drumsPitch = AVAudioUnitTimePitch()
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
        for node in processors { engine.attach(node) }
        connect()
    }

    /// The new values change the shape of the graph (`Shape`): then it must be rewired, with the engine stopped.
    public func needsRewire(transpose: Transpose, speed: Speed) -> Bool {
        Shape(transpose: transpose, speed: speed) != shape
    }

    /// Only when the shape changes the graph is rewired, and then the engine must be stopped; otherwise only
    /// the pitch changes, playing.
    public func setTranspose(_ value: Transpose) {
        let rewire = needsRewire(transpose: value, speed: speed)
        transpose = value
        timePitch.pitch = Float(value.semitones * 100)
        if rewire { connect() }
    }

    /// Like `setTranspose`. Between two speeds the rate changes, but the two time pitches would take it at
    /// different render cycles, and the drums would drift from the rest: the player reschedules
    /// (`schedule(from:)`) after setting it while playing.
    public func setSpeed(_ value: Speed) {
        let rewire = needsRewire(transpose: transpose, speed: value)
        speed = value
        timePitch.rate = Float(value.factor)
        drumsPitch.rate = Float(value.factor)
        if rewire { connect() }
    }

    /// From a sound in the stems to it in the output, past the clock node: the limiter's lookahead, after
    /// the sum; 0 at 0 semitones and 100%.
    public var latencyFrames: Int {
        shape == .off ? 0 : Self.latencyFrames(of: limiter.audioUnit, rate: sampleRate)
    }

    /// How much later than the others the drums start: the time pitch's latency, so they reach the sum
    /// with the transposed stems; 0 at 0 semitones, and at another speed, where the drums have a time
    /// pitch of their own.
    public var drumsDelayFrames: Int {
        shape == .transposed ? Self.latencyFrames(of: timePitch.audioUnit, rate: sampleRate) : 0
    }

    /// Output frames from the start of the nodes to the first sound: for the fade-in.
    public var startDelayFrames: Int {
        switch shape {
        case .off: 0
        case .transposed: drumsDelayFrames + latencyFrames
        case .stretched: Self.latencyFrames(of: timePitch.audioUnit, rate: sampleRate) + latencyFrames
        }
    }

    /// How many frames of the files have been heard since the nodes started, from the clock node's sample
    /// time (`playerTime`), never below 0. Stretched, the drums' node counts the file frames its time pitch
    /// has pulled, `factor` per output frame (measured on 28/11): what is still inside the time pitch and the
    /// limiter is their output delay in file frames. The time pitch's reported latency is off by about 11 ms
    /// at 50% and 3 ms at 125% (measured): enough for a cursor.
    public func heardFrames(clockSampleTime: AVAudioFramePosition) -> AVAudioFramePosition {
        switch shape {
        case .off, .transposed:
            return max(0, clockSampleTime - AVAudioFramePosition(latencyFrames))
        case .stretched:
            return max(0, clockSampleTime - AVAudioFramePosition((Double(startDelayFrames) * speed.factor).rounded()))
        }
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
        drumsPitch.reset()
        limiter.reset()
        let start = min(max(0, frame), lengthFrames)
        let count = AVAudioFrameCount(lengthFrames - start)
        guard count > 0 else { return }
        for (stem, node) in nodes {
            guard let file = files[stem] else { continue }
            node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil)
        }
    }

    /// The node whose time gives the position: the drums, which never go through the transposing time pitch
    /// and start as late as it delays the rest; any node at 0 semitones and 100%.
    public var clockNode: AVAudioPlayerNode {
        nodes[.drums] ?? nodes.values.first!
    }

    // MARK: - Support

    private func connect() {
        for node in nodes.values { engine.disconnectNodeOutput(node) }
        for node in processors { engine.disconnectNodeOutput(node) }
        let main = engine.mainMixerNode
        let shape = shape
        guard shape != .off, let format = files.values.first?.processingFormat else {
            for (stem, node) in nodes { engine.connect(node, to: main, format: files[stem]?.processingFormat) }
            return
        }
        for (stem, node) in nodes {
            let target: AVAudioNode = stem != .drums ? restMixer : shape == .stretched ? drumsPitch : sumMixer
            engine.connect(node, to: target, format: files[stem]?.processingFormat)
        }
        if shape == .stretched { engine.connect(drumsPitch, to: sumMixer, format: format) }
        engine.connect(restMixer, to: timePitch, format: format)
        engine.connect(timePitch, to: sumMixer, format: format)
        engine.connect(sumMixer, to: limiter, format: format)
        engine.connect(limiter, to: main, format: format)
    }

    private var processors: [AVAudioNode] { [restMixer, timePitch, drumsPitch, sumMixer, limiter] }

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
