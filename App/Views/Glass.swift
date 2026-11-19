// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import SwiftUI

/// Liquid Glass on macOS 26 and later; on macOS 15 the materials and button styles that came before it.
/// Every glass surface and glass button of the app goes through here, so the fallback is in one place.
extension View {
    /// A glass surface in `shape`, tinted with `tint` if given. Before macOS 26: the regular material,
    /// and a tinted surface is filled with the color itself.
    @ViewBuilder
    func stelixGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// The glass button style (`prominent`: filled with the accent). Before macOS 26: bordered.
    @ViewBuilder
    func stelixGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// The panel background holding `content`: `NSGlassEffectView` on macOS 26 and later, the popover
/// material before it. Both are rounded to `cornerRadius`.
@MainActor
func makePanelBackground(content: NSView, cornerRadius: CGFloat) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
    let material = NSVisualEffectView()
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    material.wantsLayer = true
    material.layer?.cornerRadius = cornerRadius
    material.layer?.masksToBounds = true
    content.frame = material.bounds
    content.autoresizingMask = [.width, .height]
    material.addSubview(content)
    return material
}
