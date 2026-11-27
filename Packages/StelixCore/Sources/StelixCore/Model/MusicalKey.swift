// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// A key as a pitch class and a mode. Stelix decides the spelling itself, also at 0 semitones:
/// for every key the one with the fewest accidentals in the key signature (Am +3 is Cm, not B♯m).
/// F♯/G♭ and D♯m/E♭m tie at six: they follow the music around (`spelling`: G♭ among flat keys,
/// Gabriele, 26/11), and without it take the sharps, so a key and its relative minor or major share the
/// signature. The names are the same in every language.
public struct MusicalKey: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable { case major, minor }
    /// The side of the key signature.
    public enum Spelling: String, Sendable, Hashable, Codable { case sharps, flats }

    /// 0 = C … 11 = B.
    public let pitchClass: Int
    public let mode: Mode
    /// How a tie is written, from the keys around it; `nil`: sharps. It does not make another key: two keys
    /// that differ only here are equal.
    public let spelling: Spelling?

    /// Any integer: it is taken modulo 12, negatives too.
    public init(pitchClass: Int, mode: Mode, spelling: Spelling? = nil) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.mode = mode
        self.spelling = spelling
    }

    public static func == (a: MusicalKey, b: MusicalKey) -> Bool {
        a.pitchClass == b.pitchClass && a.mode == b.mode
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pitchClass)
        hasher.combine(mode)
    }

    private enum CodingKeys: String, CodingKey { case pitchClass, mode, spelling }

    /// Through `init(pitchClass:mode:)`: a line from the other process could carry any integer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pitchClass: try container.decode(Int.self, forKey: .pitchClass),
                  mode: try container.decode(Mode.self, forKey: .mode),
                  spelling: try container.decodeIfPresent(Spelling.self, forKey: .spelling))
    }

    public func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(pitchClass: pitchClass + semitones, mode: mode, spelling: spelling)
    }

    public func spelled(_ spelling: Spelling?) -> MusicalKey {
        MusicalKey(pitchClass: pitchClass, mode: mode, spelling: spelling)
    }

    /// F♯ or D♯m: six accidentals either way.
    public var isTie: Bool {
        (mode == .major && pitchClass == 6) || (mode == .minor && pitchClass == 3)
    }

    /// The side its key signature leans to; `nil` for C and Am (none) and for the ties (both).
    public var side: Spelling? {
        guard !isTie else { return nil }
        let fifths = Self.majorFifths[mode == .major ? pitchClass : (pitchClass + 3) % 12]
        return fifths > 0 ? .sharps : fifths < 0 ? .flats : nil
    }

    /// A chord at home in `track`: in a major key I, ii, iii, IV, V, vi and the parallel minor; in a minor
    /// key i, III, iv, v, V, VI, VII and the parallel major. Short windows that wander among these are a
    /// song in `track` moving between its chords, not a new key.
    public func isAtHome(in track: MusicalKey) -> Bool {
        let interval = ((pitchClass - track.pitchClass) % 12 + 12) % 12
        let home: [(Int, Mode)] = track.mode == .major
            ? [(0, .major), (2, .minor), (4, .minor), (5, .major), (7, .major), (9, .minor), (0, .minor)]
            : [(0, .minor), (3, .major), (5, .minor), (7, .minor), (7, .major), (8, .major), (10, .major), (0, .major)]
        return home.contains { $0.0 == interval && $0.1 == mode }
    }

    /// "C", "F♯", "G♭", "E♭", "Am", "C♯m", "E♭m", "B♭m".
    public var name: String {
        if isTie, spelling == .flats { return mode == .major ? "G♭" : "E♭m" }
        switch mode {
        case .major: return Self.majorNames[pitchClass]
        case .minor: return Self.minorNames[pitchClass]
        }
    }

    /// The name without the mode: "C♯" for C♯m, "E♭" for E♭.
    public var tonicName: String {
        mode == .minor ? String(name.dropLast()) : name
    }

    /// Sharps (+) or flats (−) of each major key's signature with the names above; F♯ is the tie.
    private static let majorFifths = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
    private static let majorNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    private static let minorNames = ["Cm", "C♯m", "Dm", "D♯m", "Em", "Fm", "F♯m", "Gm", "G♯m", "Am", "B♭m", "Bm"]
}
