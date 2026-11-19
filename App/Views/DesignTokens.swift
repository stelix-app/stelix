// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Sizes, colors and typography of the design. 4 pt grid.
enum Tokens {
    static let panelWidth: CGFloat = 360
    static let padding: CGFloat = 16

    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let spaceXL: CGFloat = 24

    static let radiusPanel: CGFloat = 20
    static let radiusBanner: CGFloat = 12
    static let rowHeight: CGFloat = 28
}

enum Typography {
    static let title = Font.headline
    static let delay = Font.system(size: 28, weight: .semibold).monospacedDigit()
    static let delayLabel = Font.callout
    static let body = Font.body
    static let idle = Font.system(size: 17, weight: .semibold)
    static let liveStatus = Font.system(size: 17, weight: .medium)
    static let stat = Font.caption.monospacedDigit()
    static let footer = Font.callout
}

extension Stem {
    /// Muted stem color: dot only (0.85), level bar (0.6) and slider fill (`StemSlider`).
    var color: Color {
        switch self {
        case .vocals: .pink
        case .drums: .orange
        case .bass: .indigo
        case .other: .teal
        case .piano: .yellow
        case .guitar: .green
        }
    }
}
