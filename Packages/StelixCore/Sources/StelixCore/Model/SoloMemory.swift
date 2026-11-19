// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// What holding a stem's icon does. The first hold leaves that stem alone; holding it again puts back
/// the switches from before the solo. Only on/off is remembered: the volumes are always the current ones.
public struct SoloMemory: Sendable, Equatable {
    /// The stem of the last hold that started a solo, and the switches it found.
    private var saved: (stem: Stem, switches: [Stem: Bool])?

    public init() {}

    /// The mix after holding `stem`.
    public mutating func hold(_ stem: Stem, in mix: StemMix) -> StemMix {
        guard mix.controls[stem] != nil else { return mix }
        guard mix.soloStem == stem else {
            saved = (stem, mix.controls.mapValues(\.enabled))
            return mix.soloing(stem)
        }
        defer { saved = nil }
        guard let saved, saved.stem == stem else { return mix.applying(.all) }
        var restored = mix
        for (other, enabled) in saved.switches where restored.controls[other] != nil {
            restored.controls[other]?.enabled = enabled
        }
        return restored
    }

    /// A switch changed by hand (a click or a preset): holding the solo stem then turns everything on.
    public mutating func forget() {
        saved = nil
    }

    public static func == (lhs: SoloMemory, rhs: SoloMemory) -> Bool {
        lhs.saved?.stem == rhs.saved?.stem && lhs.saved?.switches == rhs.saved?.switches
    }
}
