// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Under the last stem: tempo and key on the left (macOS 27 only, where the analysis exists), the
/// transpose on the right (`StepperField`).
struct MusicRow: View {
    let bpm: Double?
    /// Already transposed: the key that is heard.
    let key: MusicalKey?
    let showsAnalysis: Bool
    let transpose: Transpose
    let onRaise: () -> Void
    let onLower: () -> Void
    let onSet: (Transpose) -> Void

    /// Tempo and key come from MusicUnderstanding, from macOS 27; the transpose works on every macOS.
    static var analysisAvailable: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    var body: some View {
        HStack(spacing: Tokens.spaceS) {
            if showsAnalysis {
                TempoLabel(bpm: bpm, key: key)
            }
            Spacer(minLength: Tokens.spaceS)
            StepperField(label: Copy.transpose, rangeLabel: Copy.transposeRange, value: transpose,
                         format: Copy.transposeValue, parse: { Transpose(typed: $0) }, spoken: Copy.transposeSpoken,
                         canRaise: transpose.canRaise, canLower: transpose.canLower,
                         onRaise: onRaise, onLower: onLower, onSet: onSet)
        }
    }
}

/// Under the transpose, in the Studio only: its speed, the same shape, aligned on the right. On its own row:
/// tempo, key, speed and transpose do not fit in one in a 360 pt panel.
struct SpeedRow: View {
    let speed: Speed
    let onRaise: () -> Void
    let onLower: () -> Void
    let onSet: (Speed) -> Void

    var body: some View {
        HStack(spacing: Tokens.spaceS) {
            Spacer(minLength: Tokens.spaceS)
            StepperField(label: Copy.speed, rangeLabel: Copy.speedRange, value: speed,
                         format: Copy.speedValue, parse: { Speed(typed: $0) }, spoken: Copy.speedSpoken,
                         canRaise: speed.canRaise, canLower: speed.canLower,
                         onRaise: onRaise, onLower: onLower, onSet: onSet)
        }
    }
}
