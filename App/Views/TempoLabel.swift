// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// "BPM: 88.3 · Key: Cm"; "—" for a value that is missing (no tempo, or no sure key): small, gray,
/// fixed-width digits, like the clock. The key's label stays even without a key (Gabriele, 26/11). The values follow the music (piani/ricerca-bpm.md); they
/// change without animation.
struct TempoLabel: View {
    let bpm: Double?
    let key: MusicalKey?

    var body: some View {
        Text(Copy.bpm(bpm) + " · " + Copy.key(key))
            .font(Typography.stat)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Copy.bpmSpoken(bpm) + ", " + Copy.keySpoken(key))
    }
}
