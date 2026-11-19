// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore

/// Draws the menu bar icon for a state: an 18 pt template image.
/// Called only when the state changes (`StatusItemController`): in Original once and that is all.
/// The images are templates (black only, with alpha): the system supplies the color.
@MainActor struct StatusIconRenderer {
    static let size = NSSize(width: 18, height: 18)

    private let idleImage: NSImage = {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Stelix") ?? NSImage()
        image.isTemplate = true
        return image
    }()

    func update(for state: StatusIconState) -> NSImage {
        switch state {
        case .idle:
            return idleImage
        case .live(let levels):
            return Self.draw { Self.drawBars(levels) }
        case .separating(let progress):
            return Self.draw { Self.drawFill(progress) }
        case .updateAvailable:
            return Self.draw { [idleImage] in Self.drawDot(over: idleImage) }
        }
    }

    /// The still icon with a dot at the top right, cut out of the waveform so it reads on its own. The
    /// waveform keeps its own size (15×16), centered as the menu bar shows `idleImage`: stretched to 18×18
    /// it grew and changed shape when the dot appeared.
    private static func drawDot(over image: NSImage) {
        let natural = image.size.width > 0 && image.size.height > 0 ? image.size : size
        let scale = min(1, size.width / natural.width, size.height / natural.height)
        let symbol = NSSize(width: natural.width * scale, height: natural.height * scale)
        image.draw(in: NSRect(x: (size.width - symbol.width) / 2, y: (size.height - symbol.height) / 2,
                              width: symbol.width, height: symbol.height))
        let radius: CGFloat = 2.75, gap: CGFloat = 1.25
        let center = NSPoint(x: size.width - radius, y: size.height - radius)
        let hole = NSRect(x: center.x - radius - gap, y: center.y - radius - gap,
                          width: 2 * (radius + gap), height: 2 * (radius + gap))
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: hole).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()
    }

    private static func draw(_ body: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            body()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Stelix"
        return image
    }

    /// Three centered vertical capsules: from a dot (3 pt) to 14 pt, depending on the level.
    private static func drawBars(_ levels: [Float]) {
        let width: CGFloat = 3, gap: CGFloat = 2.5
        let minHeight: CGFloat = 3, maxHeight: CGFloat = 14
        let total = 3 * width + 2 * gap
        let originX = (size.width - total) / 2
        for index in 0..<3 {
            let level = CGFloat(min(max(index < levels.count ? levels[index] : 0, 0), 1))
            let height = minHeight + (maxHeight - minHeight) * level
            let rect = NSRect(
                x: originX + CGFloat(index) * (width + gap), y: (size.height - height) / 2,
                width: width, height: height)
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    /// A thin ring that closes clockwise around three still bars (a small
    /// `waveform`). The track is at 0.35 alpha: it reads even at 0 %, and the fill is seen growing.
    private static func drawFill(_ progress: Double) {
        let progress = min(max(progress, 0), 1)
        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 7.75, lineWidth: CGFloat = 1.5

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.stroke()

        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius, startAngle: 90,
                endAngle: 90 - 360 * CGFloat(progress), clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = progress < 1 ? .round : .butt
            NSColor.black.setStroke()
            arc.stroke()
        }

        let heights: [CGFloat] = [3, 6, 3.5]
        let width: CGFloat = 1.5, gap: CGFloat = 1.5
        let originX = center.x - (3 * width + 2 * gap) / 2
        for (index, height) in heights.enumerated() {
            let rect = NSRect(
                x: originX + CGFloat(index) * (width + gap), y: center.y - height / 2,
                width: width, height: height)
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}
