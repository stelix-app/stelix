// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The icon of a stem, in place of the dot: SF Symbols where they exist (voice, piano, other),
/// hand-drawn for drums, bass and guitar, which SF Symbols do not have on their own.
/// Takes its color from the `foregroundStyle` of whoever uses it.
///
/// All six are template `NSImage`s shown with `Image(nsImage:)`, the symbols too. With a muted stem the
/// style is `.tertiary`, a vibrant one: on the glass a filled `Shape` and an SF Symbol came out in two
/// different grays (13/11). The same kind of image gets the same gray.
struct StemIcon: View {
    let stem: Stem
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: StemIconImages.image(stem, size: size))
            .renderingMode(.template)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The template images of `StemIcon`, made once per stem and size.
@MainActor enum StemIconImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ stem: Stem, size: CGFloat) -> NSImage {
        let key = "\(stem.rawValue)-\(size)"
        if let image = cache[key] { return image }
        let image = make(stem, size: size)
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func make(_ stem: Stem, size: CGFloat) -> NSImage {
        switch stem {
        case .drums: glyph(DrumGlyph(), size: size)
        case .bass: glyph(StringGlyph(kind: .bass), size: size)
        case .guitar: glyph(StringGlyph(kind: .guitar), size: size)
        case .vocals: symbol("microphone.fill", size: size)
        case .piano: symbol("pianokeys", size: size)
        case .other: symbol("music.note", size: size)
        }
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.85, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: size, height: size))
    }

    /// Drawn at every scale (the handler runs again for each resolution), with y pointing down as in SwiftUI.
    private static func glyph(_ shape: some Shape & Sendable, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(shape.path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
    }
}

/// The hand-drawn glyphs are `Shape`s, not `Canvas`: a Canvas paints `.foreground` into its own bitmap,
/// and with a muted stem (`.tertiary`, a vibrant style) on the glass of the Studio the icon vanished.
/// Now they are drawn into the template images above.

/// A snare drum seen from three quarters with two crossed sticks over it.
private struct DrumGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let line = max(w * 0.09, 1)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * w, y: rect.minY + y * h, width: width * w, height: height * h)
        }

        var sticks = Path()
        sticks.move(to: p(0.36, 0.44)); sticks.addLine(to: p(0.80, 0.06))
        sticks.move(to: p(0.64, 0.44)); sticks.addLine(to: p(0.20, 0.06))
        let stickStroke = sticks.strokedPath(StrokeStyle(lineWidth: line, lineCap: .round))

        // Solid shell; the head on top stays empty (it also cuts the sticks), with the rim.
        let top = box(0.06, 0.38, 0.88, 0.26)
        var shell = Path(box(0.06, 0.51, 0.88, 0.30))
        shell.addEllipse(in: box(0.06, 0.68, 0.88, 0.26))
        let rim = Path(ellipseIn: top.insetBy(dx: line / 2, dy: line / 2)).strokedPath(StrokeStyle(lineWidth: line))
        return stickStroke.union(shell).subtracting(Path(ellipseIn: top)).union(rim)
    }
}

/// Electric bass (two-horn body, long neck, 2+2 tuners) or acoustic guitar
/// (figure-eight body with the sound hole, short neck, 3+3 tuners). Drawn vertically in a
/// unit square, then rotated 40° as in instrument icons.
private struct StringGlyph: Shape {
    enum Kind { case bass, guitar }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let neckTop: CGFloat = kind == .bass ? 0.10 : 0.20
        let pegs: [CGFloat] = kind == .bass ? [0.02, 0.07] : [neckTop - 0.12, neckTop - 0.08, neckTop - 0.04]

        // Headstock and tuners.
        var shape = Path(roundedRect: CGRect(x: 0.45, y: neckTop - 0.14, width: 0.10, height: 0.15), cornerRadius: 0.03)
        for y in pegs {
            for x in [0.43, 0.57] as [CGFloat] {
                shape.addEllipse(in: CGRect(x: x - 0.025, y: y + 0.005, width: 0.05, height: 0.04))
            }
        }
        // Neck.
        shape.addRect(CGRect(x: 0.47, y: neckTop, width: 0.06, height: 0.62 - neckTop))

        // Body.
        var body = Path()
        switch kind {
        case .bass:
            body.addEllipse(in: CGRect(x: 0.26, y: 0.66, width: 0.48, height: 0.32))
            body.addEllipse(in: CGRect(x: 0.30, y: 0.46, width: 0.14, height: 0.36))
            body.addEllipse(in: CGRect(x: 0.56, y: 0.54, width: 0.13, height: 0.28))
        case .guitar:
            body.addEllipse(in: CGRect(x: 0.33, y: 0.48, width: 0.34, height: 0.28))
            body.addEllipse(in: CGRect(x: 0.27, y: 0.66, width: 0.46, height: 0.34))
        }
        var glyph = shape.union(body)
        if kind == .guitar {
            glyph = glyph.subtracting(Path(ellipseIn: CGRect(x: 0.44, y: 0.63, width: 0.12, height: 0.12)))
        }

        // From the unit square to `rect`: centered, rotated 40°, scaled by 1.1.
        let s = min(rect.width, rect.height) * 1.1
        let transform = CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: .pi * 40 / 180))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return glyph.applying(transform)
    }
}
