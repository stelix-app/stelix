#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
// Writes build/click.wav: one click every 2 s for 60 s, stereo 48 kHz. Used to test the delay measurement
// (debugMeasureDelay): with clicks the cross-correlation has a single, sharp peak.
//
//   swift scripts/make-clicktrack.swift [output.wav]

import AVFoundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appending(path: "build/click.wav")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

let rate = 48_000.0
let seconds = 60
let frames = AVAudioFrameCount(rate) * AVAudioFrameCount(seconds)
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
for c in 0..<2 { buffer.floatChannelData![c].update(repeating: 0, count: Int(frames)) }

// Click: 6 ms of a 2 kHz sine with a decaying envelope, at -2 dBFS.
let clickFrames = Int(0.006 * rate)
for start in stride(from: 0, to: Int(frames), by: Int(2 * rate)) {
    for i in 0..<clickFrames where start + i < Int(frames) {
        let t = Double(i) / rate
        let v = Float(0.8 * sin(2 * .pi * 2_000 * t) * exp(-t / 0.0015))
        for c in 0..<2 { buffer.floatChannelData![c][start + i] = v }
    }
}

try? FileManager.default.removeItem(at: out)
let file = try AVAudioFile(forWriting: out, settings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: rate,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
], commonFormat: .pcmFormatFloat32, interleaved: false)
try file.write(from: buffer)
file.close()   // a global is never deallocated: without close the header stays at 0 frames
print("written \(out.path): \(seconds) s, one click every 2 s")
