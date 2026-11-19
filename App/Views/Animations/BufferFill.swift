// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import SwiftUI

/// Buffer bar: follows `fraction` with a soft movement while Live fills up.
struct BufferFill: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CapsuleBar(fraction: fraction)
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: fraction)
    }
}
