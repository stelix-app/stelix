// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Mode selector: three tall full-width glass capsules, the same shape as
/// Record and Choose File. Over the chosen section sits one accent capsule, a single one, that
/// slides **only horizontally**: its position is an offset computed on the width of the
/// selector, not a shared geometry (`matchedGeometryEffect` works in the window's
/// coordinates and, when the panel changes height entering or leaving Live, made it move
/// vertically too). Three layers: glass below, colored glass capsule in the middle, text and click on top.
struct ModePicker: View {
    let controller: ModeController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The section the capsule is on. It follows `controller.selected` one turn later: in the turn of the
    /// change the panel changes height (Live is taller) and the content shifts for an
    /// instant vertically; if the capsule animated there, it would chase that too (diagonally).
    @State private var shown: Mode

    init(controller: ModeController) {
        self.controller = controller
        _shown = State(initialValue: controller.selected)
    }

    static let height: CGFloat = 32
    /// The slide: soft, no bounce. Only `shown` changes inside the animation.
    static let slide = Animation.smooth(duration: 0.3)

    private var shownIndex: Int { Mode.allCases.firstIndex(of: shown) ?? 0 }

    var body: some View {
        ZStack {
            row { _ in
                Capsule().fill(.clear)
                    .stelixGlass(in: Capsule())
            }
            GeometryReader { geometry in
                let count = CGFloat(Mode.allCases.count)
                let width = (geometry.size.width - Tokens.spaceS * (count - 1)) / count
                // Glass too, tinted with the accent: same borders and same light as the others.
                Capsule().fill(.clear)
                    .stelixGlass(in: Capsule(), tint: .accentColor)
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: CGFloat(shownIndex) * (width + Tokens.spaceS))
            }
            .allowsHitTesting(false)
            row { mode in
                let selected = mode == shown
                Button { controller.select(mode) } label: {
                    Text(Copy.name(mode))
                        .fontWeight(.medium)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: Self.height)
        .onChange(of: controller.selected) { _, mode in
            DispatchQueue.main.async {
                if reduceMotion {
                    shown = mode
                } else {
                    withAnimation(Self.slide) { shown = mode }
                }
            }
        }
    }

    /// The three cells of equal width, with the same step for all layers.
    private func row(@ViewBuilder _ cell: @escaping (Mode) -> some View) -> some View {
        HStack(spacing: Tokens.spaceS) {
            ForEach(Mode.allCases, id: \.self) { mode in
                cell(mode).frame(maxWidth: .infinity)
            }
        }
    }
}
