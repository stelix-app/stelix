// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Shortcuts that turn stems on or off without touching the volumes.
public enum Preset: String, Codable, Sendable, CaseIterable {
    case soloVoice, noVoice, all

    func enables(_ stem: Stem) -> Bool {
        switch self {
        case .soloVoice: stem == .vocals
        case .noVoice: stem != .vocals
        case .all: true
        }
    }
}

public struct StemControl: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// 0...1
    public var volume: Float

    public init(enabled: Bool, volume: Float) {
        self.enabled = enabled
        self.volume = volume
    }
}

/// The mixer state: for each stem present, on or off and volume.
public struct StemMix: Codable, Sendable, Equatable {
    public var controls: [Stem: StemControl]

    public init(controls: [Stem: StemControl]) {
        self.controls = controls
    }

    public static func allOn(_ stems: [Stem]) -> StemMix {
        StemMix(controls: Dictionary(uniqueKeysWithValues: stems.map { ($0, StemControl(enabled: true, volume: 1)) }))
    }

    /// Changes only `enabled`: the volumes stay as chosen.
    public func applying(_ preset: Preset) -> StemMix {
        var copy = self
        for stem in controls.keys {
            copy.controls[stem]?.enabled = preset.enables(stem)
        }
        return copy
    }

    /// Only `stem` on, the others off; the volumes stay as chosen. A stem not in the mix changes nothing.
    public func soloing(_ stem: Stem) -> StemMix {
        guard controls[stem] != nil else { return self }
        var copy = self
        for other in controls.keys {
            copy.controls[other]?.enabled = other == stem
        }
        return copy
    }

    /// The stem that plays alone: the only one on, if exactly one is.
    public var soloStem: Stem? {
        let on = controls.filter { $0.value.enabled }
        return on.count == 1 ? on.first?.key : nil
    }

    /// Mixer gain: the volume if the stem is on, otherwise 0. An absent stem is 0.
    public func effectiveGain(_ stem: Stem) -> Float {
        guard let control = controls[stem], control.enabled else { return 0 }
        return control.volume
    }

    /// The preset whose switches match the current ones, to highlight it in the UI.
    public var matchingPreset: Preset? {
        Preset.allCases.first { preset in
            controls.allSatisfy { stem, control in control.enabled == preset.enables(stem) }
        }
    }
}
