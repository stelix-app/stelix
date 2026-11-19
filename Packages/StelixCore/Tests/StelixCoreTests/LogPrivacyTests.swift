// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct LogPrivacyTests {
    /// AVFoundation and MusicUnderstanding put the file's URL in the error: only domain and code are shown.
    @Test func anErrorNeverNamesTheFile() {
        let url = URL(fileURLWithPath: "/Users/x/Music/Canzone segreta.mp3")
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11828, userInfo: [
            NSURLErrorKey: url, NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "Cannot open \(url.path)",
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12847, userInfo: [NSURLErrorKey: url]),
        ])
        let text = LogPrivacy.describe(error: error)
        #expect(text == "AVFoundationErrorDomain -11828")
        #expect(!text.contains("Canzone"))
    }

    /// The engine's own failures keep their code, message and detail (a model or stem name).
    @Test func anEngineFailureKeepsItsCode() {
        #expect(LogPrivacy.describe(error: EngineFailure(.modelMissingStem, detail: "drums")) == "model modelMissingStem drums")
        #expect(LogPrivacy.describe(error: EngineFailure(.separationCancelled)) == "cancelled separationCancelled")
    }

    @Test func markedValuesBecomePrivate() {
        let line = "live: \(LogPrivacy.mark("AirPods di Gabriele")) [\(LogPrivacy.mark("AA-BB-CC-DD-EE-FF:output"))] 48000 Hz"
        #expect(LogPrivacy.redact(line, home: "/Users/x") == "live: <private> [<private>] 48000 Hz")
    }

    @Test func textWithoutMarksStaysAsItIs() {
        let line = "live: model htdemucs ready in 412 ms"
        #expect(LogPrivacy.redact(line, home: "/Users/x") == line)
    }

    /// A Python traceback or a library error may name a file under the user's home folder.
    @Test func homeFolderBecomesTilde() {
        let line = "FileNotFoundError: '/Users/gabriele/Library/Application Support/Stelix/Models/roformer/x.yaml'"
        #expect(LogPrivacy.redact(line, home: "/Users/gabriele")
            == "FileNotFoundError: '~/Library/Application Support/Stelix/Models/roformer/x.yaml'")
    }

    @Test func emptyHomeChangesNothing() {
        #expect(LogPrivacy.redact("player: 6 stems", home: "") == "player: 6 stems")
    }

    /// The end of the mark was lost (a line cut in two): nothing after the opening is shown.
    @Test func markLeftOpenHidesTheRestOfTheText() {
        let cut = String(LogPrivacy.mark("Cuffie di Gabriele").dropLast(9))
        #expect(LogPrivacy.redact("rec: \(cut)", home: "/Users/x") == "rec: <private>")
    }

    /// A value that contains the closing character must not show what comes after it.
    @Test func valueCannotCloseItsOwnMark() {
        let value = "secret\u{2}title"
        #expect(LogPrivacy.redact("studio: \(LogPrivacy.mark(value)), 3.0 s", home: "/Users/x")
            == "studio: <private>, 3.0 s")
    }

    @Test func valueStartingWithCombiningMarkIsStillHidden() {
        #expect(LogPrivacy.redact("rec: \(LogPrivacy.mark("\u{301}Secret")) 48000 Hz", home: "/Users/x")
            == "rec: <private> 48000 Hz")
    }

    @Test func homeOfAnotherUserWithTheSamePrefixIsNotCut() {
        #expect(LogPrivacy.redact("open /Users/anna/a.py and /Users/ann/b.py", home: "/Users/ann")
            == "open /Users/anna/a.py and ~/b.py")
    }

    /// What the engine writes about a file the user gave it: the type, never the name or the folder.
    @Test func fileDescriptionHasOnlyTheExtension() {
        let url = URL(fileURLWithPath: "/Users/gabriele/Music/Artist - Secret Title.MP3")
        #expect(LogPrivacy.describe(file: url) == "mp3 file")
        #expect(LogPrivacy.describe(file: URL(fileURLWithPath: "/tmp/no extension")) == "file")
    }

    /// An "extension" that is really part of a title (a name with a dot and no real extension).
    @Test func longOrOddExtensionIsNotShown() {
        #expect(LogPrivacy.describe(file: URL(fileURLWithPath: "/tmp/Mr. Secret Title")) == "file")
        #expect(LogPrivacy.describe(file: URL(fileURLWithPath: "/tmp/a.b c")) == "file")
    }
}

struct LogRelayTests {
    @Test func linesComeOutWholeWhenChunksSplitThem() {
        var relay = LogRelay(home: "/Users/x")
        let text = "studio: \(LogPrivacy.mark("Secret Title.mp3")), 12.0 s\nplayer: 6 stems\n"
        let bytes = Data(text.utf8)
        // The cut falls inside the marked value.
        #expect(relay.feed(bytes[..<14]).isEmpty)
        #expect(relay.feed(bytes[14...]) == ["studio: <private>, 12.0 s", "player: 6 stems"])
    }

    @Test func emptyLinesAreDropped() {
        var relay = LogRelay(home: "/Users/x")
        #expect(relay.feed(Data("\n\nlive: new attempt\n\n".utf8)) == ["live: new attempt"])
    }

    @Test func finishReturnsTheLineLeftWithoutNewline() {
        var relay = LogRelay(home: "/Users/x")
        #expect(relay.feed(Data("Traceback from /Users/x/a.py".utf8)).isEmpty)
        #expect(relay.finish() == ["Traceback from ~/a.py"])
        #expect(relay.finish().isEmpty)
    }

    /// The cap cuts a line inside a marked value: the second piece must not show the rest of it.
    @Test func cutInsideMarkedValueStaysHidden() {
        var relay = LogRelay(home: "/Users/x")
        let text = String(repeating: "a", count: LogRelay.maxLineBytes - 3) + LogPrivacy.mark("SECRETVALUE") + " tail\n"
        let lines = relay.feed(Data(text.utf8))
        #expect(lines.count == 2)
        #expect(!lines.joined().contains("SE"))
        #expect(!lines.joined().contains("VALUE"))
        #expect(lines.first?.hasSuffix("a<private>") == true)
        #expect(lines.last == "<private> tail")
        // The next line starts in clear again.
        #expect(relay.feed(Data("player: 6 stems\n".utf8)) == ["player: 6 stems"])
    }

    /// Output that never ends a line (a progress bar) must not pile up: it comes out in pieces.
    @Test func lineThatNeverEndsComesOutInPieces() {
        var relay = LogRelay(home: "/Users/x")
        var lines: [String] = []
        for _ in 0..<10 { lines += relay.feed(Data(repeating: 0x61, count: LogRelay.maxLineBytes / 4)) }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.utf8.count == LogRelay.maxLineBytes })
        #expect(relay.finish().map(\.utf8.count) == [LogRelay.maxLineBytes / 2])
    }
}
