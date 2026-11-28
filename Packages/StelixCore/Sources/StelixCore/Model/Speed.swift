// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// How fast the Studio plays, in percent, from 50 to 150; 100 is the track as it is. The pitch never
/// changes with it (time stretch, not tape). At 100 the audio does not go through a time pitch for it.
public struct Speed: Sendable, Equatable, Hashable {
    public static let range: ClosedRange<Int> = 50...150
    /// What one arrow moves; the arrows snap to multiples of it.
    public static let step = 5
    public static let normal = Speed(percent: 100)

    public let percent: Int

    /// Values outside `range` are clamped to it.
    public init(percent: Int) {
        self.percent = min(max(percent, Self.range.lowerBound), Self.range.upperBound)
    }

    /// What the user typed in the panel's field: a whole number, optionally followed by "%". `nil` for
    /// anything else, including values outside `range`: those are refused, not clamped.
    public init?(typed text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.hasSuffix("%") { rest = rest.dropLast() }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty, rest.count <= 3, rest.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(rest), Self.range.contains(value) else { return nil }
        self.init(percent: value)
    }

    public var isNormal: Bool { percent == 100 }
    public var canRaise: Bool { percent < Self.range.upperBound }
    public var canLower: Bool { percent > Self.range.lowerBound }
    /// The rate of the time pitch: 0.75 at 75%.
    public var factor: Double { Double(percent) / 100 }

    /// The next multiple of `step` above; stays at 150.
    public func raised() -> Speed { Speed(percent: (percent / Self.step + 1) * Self.step) }

    /// The next multiple of `step` below; stays at 50.
    public func lowered() -> Speed {
        let below = percent % Self.step == 0 ? percent - Self.step : percent / Self.step * Self.step
        return Speed(percent: below)
    }

    /// Appended to the name of a saved Studio folder, after the semitones: "" at 100, " 75%".
    public var folderSuffix: String {
        isNormal ? "" : " \(percent)%"
    }
}
