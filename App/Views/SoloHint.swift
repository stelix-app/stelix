// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import SwiftUI

/// The line under the stems that says how to solo one. It goes away for good at the first solo,
/// in Live or Studio, without an animation (Gabriele, 18/11).
struct SoloHint: View {
    /// Set by the views on every solo; read from the panel's `defaultAppStorage`.
    static let seenKey = "soloHintSeen"
    @AppStorage(SoloHint.seenKey) private var seen = false

    var body: some View {
        if !seen {
            Text(Copy.stemSoloHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
