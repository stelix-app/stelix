// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The key of one window of the Studio's source; `nil`: the analysis found none.
public struct KeyWindow: Codable, Sendable, Equatable {
    /// The window starts at `index × KeyScan.hop` seconds.
    public let index: Int
    public let key: MusicalKey?

    public init(index: Int, key: MusicalKey?) {
        self.index = index
        self.key = key
    }
}

/// The Studio key over the whole clip. On the whole file Apple gives one key for the track, so a
/// modulation or a section in another key never shows; windows of `seconds` every `hop` do. The engine
/// analyzes them in the background and the stems never wait. A key shows only where
/// `KeyFollower.confirmations` windows in a row agree, like the Live (a gap of one or two windows between
/// two sections in the same key is bridged); where the windows wander among the chords at home in the
/// key Apple gives for the whole track, that key. Elsewhere, or where the windows are not in yet, nothing.
public struct KeyScan: Codable, Sendable, Equatable {
    public static let seconds = 20.0
    public static let hop = 4.0
    /// Windows analyzed at once: one, so the scan takes as little as it can from the separation it runs
    /// alongside (Gabriele, 27/11). The near ones still come first, in about a second.
    public static let concurrent = 1

    /// The source's duration as the engine read it: it fixes the windows.
    public let duration: Double
    /// In the order they arrived, at most one per index.
    public private(set) var windows: [KeyWindow]
    /// The key Apple gives for the whole track (one for all of it): the fallback where the windows wander.
    public private(set) var trackKey: MusicalKey?
    /// The whole track was analyzed for its key, found or not.
    public private(set) var trackChecked = false

    /// Sections this far apart (in windows) in the same key are one.
    public static let bridge = 2
    /// The fallback wants this share of the windows around (two each side) at home in the track's key.
    public static let homeShare = 0.8

    public init(duration: Double, windows: [KeyWindow] = []) {
        self.duration = duration
        self.windows = []
        for window in windows { add(window) }
    }

    private enum CodingKeys: String, CodingKey { case duration, windows, trackKey, trackChecked }

    /// Windows go through `add` (an index out of range is dropped); a scan without the track fields is one
    /// whose track was not looked at yet.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(duration: try container.decode(Double.self, forKey: .duration),
                  windows: try container.decode([KeyWindow].self, forKey: .windows))
        trackKey = try container.decodeIfPresent(MusicalKey.self, forKey: .trackKey)
        trackChecked = try container.decodeIfPresent(Bool.self, forKey: .trackChecked) ?? false
    }

    /// Full windows only: a clip shorter than `seconds` has none.
    public var windowCount: Int {
        duration < Self.seconds ? 0 : Int(((duration - Self.seconds) / Self.hop + 1e-9).rounded(.down)) + 1
    }

    public func start(of index: Int) -> Double { Double(index) * Self.hop }

    private func center(of index: Int) -> Double { start(of: index) + Self.seconds / 2 }

    public var isComplete: Bool { windows.count >= windowCount && trackChecked }

    public mutating func setTrackKey(_ key: MusicalKey?) {
        trackKey = key
        trackChecked = true
    }

    /// A window, replacing one with the same index.
    public mutating func add(_ window: KeyWindow) {
        guard window.index >= 0, window.index < windowCount else { return }
        if let at = windows.firstIndex(where: { $0.index == window.index }) {
            windows[at] = window
        } else {
            windows.append(window)
        }
    }

    /// The missing window whose center is nearest to `position` (seconds), ahead on a tie; `nil` when none is
    /// missing. Where the user listens comes first: after a seek the key there arrives in a few windows.
    /// `excluding`: windows already being analyzed.
    public func next(around position: Double, excluding busy: Set<Int> = []) -> Int? {
        let done = Set(windows.map(\.index)).union(busy)
        return (0..<windowCount).filter { !done.contains($0) }.min { a, b in
            let da = abs(center(of: a) - position), db = abs(center(of: b) - position)
            return da == db ? a > b : da < db
        }
    }

    /// The sections: runs of consecutive windows with the same key, at least `KeyFollower.confirmations`
    /// long (all of them, at least two, on a clip with fewer windows), with gaps up to `bridge` windows
    /// between two runs in the same key filled; then the track's key where the windows around are at home
    /// in it. Window `i` stands for half a hop each side of its center; the first from 0, the last to the end.
    public var spans: [KeySpan] {
        let count = windowCount
        let needed = min(KeyFollower.confirmations, count)
        guard needed >= 2 else { return [] }
        let byIndex = Dictionary(windows.map { ($0.index, $0.key) }, uniquingKeysWith: { _, new in new })
        var labels = [MusicalKey?](repeating: nil, count: count)
        var runs: [(first: Int, last: Int, key: MusicalKey)] = []
        var first = 0
        while first < count {
            guard case let key?? = byIndex[first] else {
                first += 1
                continue
            }
            var last = first
            while last + 1 < count, byIndex[last + 1] == .some(key) { last += 1 }
            if last - first + 1 >= needed {
                let spelled = key.isTie ? key.spelled(side(before: first, after: last, in: byIndex)) : key
                runs.append((first, last, spelled))
            }
            first = last + 1
        }
        for (index, run) in runs.enumerated() {
            for window in run.first...run.last { labels[window] = run.key }
            if index > 0 {
                let previous = runs[index - 1]
                let gap = (previous.last + 1)..<run.first
                if !gap.isEmpty, gap.count <= Self.bridge, previous.key == run.key,
                   gap.allSatisfy({ byIndex[$0] != nil }) {
                    for window in gap { labels[window] = run.key }
                }
            }
        }
        if let track = trackKey.map({ $0.isTie ? $0.spelled(majoritySide(in: byIndex)) : $0 }) {
            for window in 0..<count where labels[window] == nil {
                let around = max(0, window - 2)...min(count - 1, window + 2)
                guard around.allSatisfy({ byIndex[$0] != nil }) else { continue }
                let home = around.filter { (byIndex[$0] ?? nil)?.isAtHome(in: track) == true }.count
                if Double(home) >= Self.homeShare * Double(around.count) { labels[window] = track }
            }
        }
        var spans: [KeySpan] = []
        for window in 0..<count {
            guard let key = labels[window] else { continue }
            let start = window == 0 ? 0 : center(of: window) - Self.hop / 2
            let end = window == count - 1 ? duration : center(of: window) + Self.hop / 2
            if let last = spans.last, last.key == key, last.end == start {
                spans[spans.count - 1] = KeySpan(start: last.start, end: end, key: last.key)
            } else {
                spans.append(KeySpan(start: start, end: end, key: key))
            }
        }
        return spans
    }

    /// The side most windows lean to: how a whole track in F♯/G♭ is written.
    private func majoritySide(in byIndex: [Int: MusicalKey?]) -> MusicalKey.Spelling? {
        let sides = byIndex.values.compactMap { $0?.side }
        let flats = sides.filter { $0 == .flats }.count
        return flats * 2 > sides.count ? .flats : sides.isEmpty ? nil : .sharps
    }

    /// How F♯/G♭ (or D♯m/E♭m) is written between windows `first` and `last`: the side of the nearest window
    /// before that leans to one, else of the nearest after; `nil` (sharps) if none does. Unsure windows count
    /// too: they still say where the music is.
    private func side(before first: Int, after last: Int, in byIndex: [Int: MusicalKey?]) -> MusicalKey.Spelling? {
        let before = stride(from: first - 1, through: 0, by: -1).lazy.compactMap { byIndex[$0] ?? nil }.compactMap(\.side).first
        let after = (last + 1..<max(last + 1, windowCount)).lazy.compactMap { byIndex[$0] ?? nil }.compactMap(\.side).first
        return before ?? after
    }

    /// The key of the section that contains `time`, or `nil`.
    public func key(at time: Double) -> MusicalKey? {
        spans.first { $0.start <= time && (time < $0.end || ($0.end == duration && time <= duration)) }?.key
    }
}
