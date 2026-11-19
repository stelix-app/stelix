// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import SwiftUI

/// Meter of one stem: a 24×4 capsule that follows the level smoothly.
/// Without a value only the background stays. With "Reduce Motion" it jumps to the value without animating.
struct StemLevelMeter: View {
    let value: Double?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 24

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) {
                if let value {
                    Capsule().fill(color)
                        .frame(width: Self.width * min(max(value, 0), 1))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: value)
                }
            }
            .frame(width: Self.width, height: 4)
    }
}

extension View {
    /// Cascade entrance: each row appears 40 ms after the previous one. Still with "Reduce Motion".
    func cascadeIn(index: Int) -> some View { modifier(CascadeIn(index: index)) }
}

private struct CascadeIn: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || shown ? 1 : 0)
            .offset(y: reduceMotion || shown ? 0 : 8)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.smooth(duration: 0.25).delay(0.04 * Double(index))) { shown = true }
            }
    }
}
