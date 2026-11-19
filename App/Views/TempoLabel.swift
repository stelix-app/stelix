// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import SwiftUI

/// "BPM: 88.3", or "BPM: —" when there is no tempo: small, gray, fixed-width digits, like the clock.
/// The number follows the music (piani/ricerca-bpm.md); it changes without animation.
struct TempoLabel: View {
    let bpm: Double?

    var body: some View {
        Text(Copy.bpm(bpm))
            .font(Typography.stat)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Copy.bpmSpoken(bpm))
    }
}
