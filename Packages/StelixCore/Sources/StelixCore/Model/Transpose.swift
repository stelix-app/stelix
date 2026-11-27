// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// How many semitones the music is moved, from -12 to +12. At 0 the audio does not go through
/// the pitch shifter at all. The drums are never transposed.
public struct Transpose: Sendable, Equatable, Hashable {
    public static let range: ClosedRange<Int> = -12...12
    public static let off = Transpose(semitones: 0)

    public let semitones: Int

    /// Values outside `range` are clamped to it.
    public init(semitones: Int) {
        self.semitones = min(max(semitones, Self.range.lowerBound), Self.range.upperBound)
    }

    /// What the user typed in the panel's field: "5", "+5", "-3", "−3" (the minus the field shows),
    /// optionally followed by "st". `nil` for anything else, including values outside `range`: those
    /// are refused, not clamped.
    public init?(typed text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.hasSuffix("st") { rest = rest.dropLast(2) }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        var sign = 1
        if let first = rest.first, "+-\u{2212}".contains(first) {
            sign = first == "+" ? 1 : -1
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, rest.count <= 2, rest.allSatisfy({ $0.isASCII && $0.isNumber }),
              let magnitude = Int(rest), Self.range.contains(sign * magnitude) else { return nil }
        self.init(semitones: sign * magnitude)
    }

    public var isOff: Bool { semitones == 0 }
    public var canRaise: Bool { semitones < Self.range.upperBound }
    public var canLower: Bool { semitones > Self.range.lowerBound }

    /// One semitone up; stays at +12.
    public func raised() -> Transpose { Transpose(semitones: semitones + 1) }

    /// One semitone down; stays at -12.
    public func lowered() -> Transpose { Transpose(semitones: semitones - 1) }

    /// Appended to the name of a saved Studio folder: "" when off, " +3 st", " -5 st".
    /// A plain hyphen, not the typographic minus: it is a file name.
    public var folderSuffix: String {
        isOff ? "" : " \(semitones > 0 ? "+" : "-")\(abs(semitones)) st"
    }
}
