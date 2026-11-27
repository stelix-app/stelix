// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// One time range of a key analysis (Apple's MusicUnderstanding in the engine).
public struct KeySpan: Sendable, Equatable, Codable {
    /// Seconds.
    public let start: Double
    /// Seconds, exclusive.
    public let end: Double
    public let key: MusicalKey

    public init(start: Double, end: Double, key: MusicalKey) {
        self.start = start
        self.end = end
        self.key = key
    }
}

/// The key at the playback instant, from the ranges of an analysis.
public struct KeyMap: Sendable, Equatable {
    /// Between spans, or before the first and after the last, the nearest key holds for this long.
    public static let margin = 2.0

    /// Sorted by start.
    public let spans: [KeySpan]

    public init(spans: [KeySpan]) {
        self.spans = spans.sorted { $0.start < $1.start }
    }

    /// The span that contains `time` (the later-starting one if two overlap); else the nearest
    /// within `margin`; else `nil`.
    public func key(at time: Double) -> MusicalKey? {
        let started = firstSpan(startingAfter: time)
        if let containing = spans[..<started].last(where: { time < $0.end }) {
            return containing.key
        }
        let nearest = spans.min { distance($0, time) < distance($1, time) }
        guard let nearest, distance(nearest, time) <= Self.margin else { return nil }
        return nearest.key
    }

    /// Index of the first span that starts after `time` (binary search).
    private func firstSpan(startingAfter time: Double) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func distance(_ span: KeySpan, _ time: Double) -> Double {
        time < span.start ? span.start - time : max(0, time - span.end)
    }
}

/// The Live key across analyses of a sliding window. A key shows once the last `confirmations` analyses
/// agree on it (Gabriele, 26/11: an unsure key shows no value): Apple's estimates wobble on harder or less
/// tonal music (relative keys, fifths), and the first ones, on a few seconds of music, are the least
/// reliable. Once shown it stays while the analyses move among the chords at home in it (a song passing
/// through its IV or V is still in its key), and goes when `leaveAway` of the last `leaveWindow` are away
/// from home, as at a modulation; four in a row of another key take over.
public struct KeyFollower: Sendable, Equatable {
    public static let confirmations = 4
    public static let leaveWindow = 3
    public static let leaveAway = 2

    public private(set) var key: MusicalKey?
    private var last: MusicalKey?
    private var run = 0
    /// Since the key was shown, whether each of the last `leaveWindow` analyses was away from home.
    private var away: [Bool] = []
    /// The side of the last estimate that leaned to one: F♯ or G♭ follows the music before it.
    private var side: MusicalKey.Spelling?

    public init() {}

    /// The new estimate (`nil`: the analysis found no key, away from home too); returns the key to show.
    @discardableResult
    public mutating func observe(_ estimate: MusicalKey?) -> MusicalKey? {
        if let leaning = estimate?.side { side = leaning }
        run = estimate != nil && estimate == last ? run + 1 : (estimate == nil ? 0 : 1)
        last = estimate
        if let estimate, run >= Self.confirmations {
            key = estimate.isTie ? estimate.spelled(side) : estimate
            away = []
        } else if let shown = key {
            away.append(!(estimate?.isAtHome(in: shown) ?? false))
            if away.count > Self.leaveWindow { away.removeFirst() }
            if away.filter({ $0 }).count >= Self.leaveAway {
                key = nil
                away = []
            }
        }
        return key
    }

    /// The panel reopened with no pause since it closed: the key shown before stays, and the analyses
    /// from now on judge it as after any other (a run toward a new key starts over).
    public mutating func resume() {
        last = nil
        run = 0
        away = []
    }

    /// Silence or a new pipeline: a new song, the side goes too.
    public mutating func reset() {
        key = nil
        last = nil
        run = 0
        away = []
        side = nil
    }
}

/// The Live key window: the last `seconds` of music, shorter than the tempo's 20 s so a new key fills it
/// sooner; analyzed every `hop(keyShown:)` seconds, more often while no key shows, so the first key and a
/// new one after a change come sooner (Gabriele, 26/11).
public enum LiveKeyWindow {
    public static let seconds = 10.0
    public static let searchingHop = 2.0
    public static let shownHop = 4.0

    public static func hop(keyShown: Bool) -> Double { keyShown ? shownHop : searchingHop }

    /// Seconds of music for the key: the last `seconds`, not across a pause (`sincePause`); `nil` under
    /// `LiveTempoWindow.minimumMusic`, too little to say.
    public static func music(available: Double, sincePause: Double?) -> Double? {
        let music = min(available, seconds, sincePause ?? .infinity)
        return music >= LiveTempoWindow.minimumMusic ? music : nil
    }
}

/// When the Live tempo and key are due: the tempo every `LiveTempoWindow.hop`, the key every
/// `LiveKeyWindow.hop(keyShown:)`. `due` marks what it returns as done.
public struct LiveAnalysisClock: Sendable, Equatable {
    private var lastTempo = -Double.infinity
    private var lastKey = -Double.infinity
    /// The 20 Hz tick is a little late or early: a hop is due this much before its time.
    private static let slack = 0.01

    public init() {}

    public mutating func due(at now: Double, keyShown: Bool) -> (tempo: Bool, key: Bool) {
        let tempo = now - lastTempo >= LiveTempoWindow.hop - Self.slack
        let key = now - lastKey >= LiveKeyWindow.hop(keyShown: keyShown) - Self.slack
        if tempo { lastTempo = now }
        if key { lastKey = now }
        return (tempo, key)
    }
}

/// The gap between two songs: `seconds` below `LiveTempoWindow.threshold` (Gabriele, 26/11: a player
/// that starts the next song at once leaves only the silence of the files, often under a second). It
/// restarts the Live key, the key window starts after it, and a key from before a gap does not come back
/// when the panel reopens. The tempo keeps its own, longer pause.
public struct LivePauseWatch: Sendable, Equatable {
    public static let seconds = 0.5

    private var quiet = 0.0
    /// Pauses begun so far.
    public private(set) var pauses = 0
    /// Seconds since the last pause ended (0 during one); `nil` before any.
    public private(set) var musicSincePause: Double?

    public init() {}

    /// The peak of the last `seconds` of input; `true` when a pause begins.
    @discardableResult
    public mutating func observe(peak: Float, seconds: Double) -> Bool {
        let wasPaused = quiet >= Self.seconds - 1e-9
        quiet = peak >= LiveTempoWindow.threshold ? 0 : quiet + seconds
        if quiet >= Self.seconds - 1e-9 {
            musicSincePause = 0
            if !wasPaused {
                pauses += 1
                return true
            }
            return false
        }
        if let since = musicSincePause { musicSincePause = since + seconds }
        return false
    }
}
