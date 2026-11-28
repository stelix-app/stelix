// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct LineCodecTests {
    static let mix = StemMix.allOn(Stem.live).applying(.noVoice)

    static let allCommands: [Command] = [
        .startLive(level: .intermediate, mix: mix),
        .setLiveLevel(.pro),
        .setMix(mix),
        .stopLive,
        .startRecording,
        .stopRecording,
        .separateFile(path: "/tmp/a b.mp3", level: .intermediate),
        .cancelJob,
        .player(.play),
        .player(.pause),
        .player(.seek(seconds: 12.5)),
        .loadStems(StemsResult(folder: "/t/a", files: [.vocals: "/t/a/vocals.wav"], duration: 20,
                               waveforms: [.vocals: [0.5]], beats: [0.5, 1.0]), position: 7.25),
        .clearStudio,
        .setTelemetry(true),
        .debugMeasureDelay,
        .setTranspose(semitones: 3),
        .scanKeys(path: "/m/a.mp3", folder: "/m/a", done: nil),
        .scanKeys(path: "/m/a.mp3", folder: "/m/a", done: KeyScan(duration: 60, windows: [KeyWindow(index: 4, key: nil)])),
        .setTranspose(semitones: -12),
        .setSpeed(percent: 75),
        .setSpeed(percent: 150),
        .shutdown,
    ]

    static let allEvents: [Event] = [
        .ready,
        .live(.warming),
        .live(.filling(fraction: 0.4)),
        .live(.waitingForAudio),
        .live(.running),
        .live(.rebuilding),
        .live(.stopped),
        .live(.stoppedForSilence),
        .liveStats(LiveStats(delaySeconds: 0.98, modelMs: 96, load: 0.21, underruns: 0, outputIsBluetooth: true)),
        .levels([.vocals: 0.5, .drums: 0.1]),
        .recording(seconds: 1.5, peaks: [0.25, 0.5]),
        .recorded(path: "/Users/x/Music/Stelix/rec.wav"),
        .job(progress: 0.7, step: .separatingVocals),
        .stemsReady(StemsResult(folder: "/f", files: [.vocals: "vocals.wav"], duration: 10,
                                waveforms: [.vocals: [0, 0.5, 1]])),
        .stemsReady(StemsResult(folder: "/f", files: [.vocals: "vocals.wav"], duration: 10,
                                waveforms: [.vocals: [0, 0.5, 1]], beats: [0.25, 0.95, 1.65])),
        .stemsReady(StemsResult(folder: "/f", files: [.vocals: "vocals.wav"], duration: 30,
                                waveforms: [.vocals: [0, 0.5, 1]],
                                keyScan: KeyScan(duration: 30, windows: [KeyWindow(index: 0, key: MusicalKey(pitchClass: 9, mode: .minor)),
                                                                         KeyWindow(index: 1, key: nil)]))),
        .keyScan(folder: "/f", KeyScan(duration: 30, windows: [KeyWindow(index: 2, key: MusicalKey(pitchClass: 0, mode: .major))])),
        .tempo(bpm: 91.5),
        .tempo(bpm: nil),
        .key(MusicalKey(pitchClass: 9, mode: .minor)),
        .key(nil),
        .player(position: 1.5, duration: 10, playing: true),
        .permissionSuspected,
        .measuredDelay(seconds: 1.01),
        .failure(EngineFailure(.tooLong, detail: "20")),
        .failure(EngineFailure(.noStems)),
    ]

    @Test func roundTripEveryCommand() throws {
        for command in Self.allCommands {
            let line = try LineCodec.encode(command)
            var decoder = LineDecoder<Command>()
            let results = decoder.feed(line)
            #expect(results.count == 1)
            #expect(try results.first?.get() == command)
        }
    }

    @Test func roundTripEveryEvent() throws {
        for event in Self.allEvents {
            let line = try LineCodec.encode(event)
            var decoder = LineDecoder<Event>()
            let results = decoder.feed(line)
            #expect(results.count == 1)
            #expect(try results.first?.get() == event)
        }
    }

    @Test func decoderHandlesSplitChunks() throws {
        let first = Event.live(.filling(fraction: 0.25))
        let second = Event.measuredDelay(seconds: 0.99)
        let data = try LineCodec.encode(first) + LineCodec.encode(second)
        let cut1 = data.count / 3, cut2 = data.count * 2 / 3
        var decoder = LineDecoder<Event>()
        var out: [Event] = []
        for chunk in [data[0..<cut1], data[cut1..<cut2], data[cut2...]] {
            out += try decoder.feed(Data(chunk)).map { try $0.get() }
        }
        #expect(out == [first, second])
    }

    @Test func decoderReportsBadLineAndContinues() throws {
        var decoder = LineDecoder<Event>()
        let results = try decoder.feed(Data("garbage\n".utf8) + LineCodec.encode(Event.ready))
        #expect(results.count == 2)
        guard results.count == 2 else { return }
        if case .success = results[0] { Issue.record("the bad line should have given an error") }
        #expect(try results[1].get() == .ready)
    }

    @Test func encodedLineHasNoInnerNewline() throws {
        let line = try LineCodec.encode(Event.failure(EngineFailure(.stemUnreadable, detail: "a\nb")))
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
    }

    /// A line that never ends must not grow in memory until its newline: it is refused as soon as it
    /// passes the cap, what follows of it is thrown away, and the next line is read as usual.
    @Test func endlessLineFailsAtTheCapAndTheNextLineIsRead() throws {
        var decoder = LineDecoder<Event>()
        let first = decoder.feed(Data(repeating: 0x61, count: LineDecoder<Event>.maxLineBytes + 1))
        #expect(first.count == 1)
        #expect(throws: LineTooLong.self) { try first.first?.get() }
        #expect(decoder.feed(Data(repeating: 0x61, count: 4096)).isEmpty)
        let after = try decoder.feed(Data("aaa\n".utf8) + LineCodec.encode(Event.ready))
        #expect(after.count == 1)
        #expect(try after.first?.get() == .ready)
    }

    /// Over the cap a line is refused even when it is valid JSON that arrived in one piece.
    @Test func overlongLineInOneChunkIsRefused() throws {
        let huge = Event.recording(seconds: 1, peaks: [Float](repeating: 0.123456, count: 200_000))
        let line = try LineCodec.encode(huge)
        #expect(line.count > LineDecoder<Event>.maxLineBytes)
        var decoder = LineDecoder<Event>()
        let results = try decoder.feed(line + LineCodec.encode(Event.ready))
        #expect(results.count == 2)
        guard results.count == 2 else { return }
        #expect(throws: LineTooLong.self) { try results[0].get() }
        #expect(try results[1].get() == .ready)
    }

    /// The largest real line is `stemsReady`: 6 stems with 600 peaks each, plus the paths.
    @Test func largestRealEventIsUnderTheCap() throws {
        let path = "/private/var/folders/ab/" + String(repeating: "x", count: 900) + "/vocals.wav"
        let peaks = (0..<600).map { Float($0) / 599.000123 }
        let event = Event.stemsReady(StemsResult(
            folder: path, files: Dictionary(uniqueKeysWithValues: Stem.studio.map { ($0, path) }), duration: 1200,
            waveforms: Dictionary(uniqueKeysWithValues: Stem.studio.map { ($0, peaks) })))
        let line = try LineCodec.encode(event)
        #expect(line.count * 4 < LineDecoder<Event>.maxLineBytes)
        var decoder = LineDecoder<Event>()
        #expect(try decoder.feed(line).first?.get() == event)
    }

    @Test func emptyLinesAreSkipped() throws {
        var decoder = LineDecoder<Event>()
        let results = try decoder.feed(Data("\n\n".utf8) + LineCodec.encode(Event.ready))
        #expect(results.count == 1)
    }

    // MARK: LineSplitter (the sidecar's lines, which are not Codable)

    @Test func splitterReturnsLinesAndTheTail() {
        var splitter = LineSplitter(maxLineBytes: 16)
        let lines = splitter.feed(Data("one\ntw".utf8)) + splitter.feed(Data("o\nthree".utf8))
        #expect(lines.map { try? $0.get() } == [Data("one".utf8), Data("two".utf8)])
        #expect(splitter.finish() == Data("three".utf8))
        #expect(splitter.finish() == nil)
    }

    /// A line that never ends stays within the cap: refused once, thrown away up to its newline,
    /// and the line after it arrives.
    @Test func splitterCapsALineThatNeverEnds() {
        var splitter = LineSplitter(maxLineBytes: 16)
        var results: [Result<Data, LineTooLong>] = []
        for _ in 0..<1000 { results += splitter.feed(Data(repeating: 0x61, count: 10)) }
        #expect(results.count == 1)
        #expect(throws: LineTooLong.self) { try results[0].get() }
        results = splitter.feed(Data("aaa\nnext\n".utf8))
        #expect(results.map { try? $0.get() } == [Data("next".utf8)])

        // The pipe closes in the middle of a refused line: nothing is left to parse.
        var cut = LineSplitter(maxLineBytes: 16)
        _ = cut.feed(Data(repeating: 0x61, count: 40))
        #expect(cut.finish() == nil)
    }

    /// A line from an engine without the tempo analysis: the stems arrive, with no beats.
    @Test func stemsWithoutBeatsStillDecode() throws {
        let line = #"{"stemsReady":{"_0":{"folder":"/f","files":{},"duration":10,"waveforms":{}}}}"# + "\n"
        var decoder = LineDecoder<Event>()
        let event = try #require(try decoder.feed(Data(line.utf8)).first?.get())
        guard case .stemsReady(let result) = event else { Issue.record("not stemsReady"); return }
        #expect(result.beats == nil)
        #expect(result.duration == 10)
    }

    /// A line from a 1.0.0 engine: the stems arrive, with no keys.
    @Test func stemsWithoutKeysStillDecode() throws {
        let line = #"{"stemsReady":{"_0":{"folder":"/f","files":{},"duration":10,"waveforms":{},"beats":[0.5,1]}}}"# + "\n"
        var decoder = LineDecoder<Event>()
        let event = try #require(try decoder.feed(Data(line.utf8)).first?.get())
        guard case .stemsReady(let result) = event else { Issue.record("not stemsReady"); return }
        #expect(result.keyScan == nil)
        #expect(result.beats == [0.5, 1])
    }
}
