// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

// Draws scripts/dmg/background.tiff, the background of the disk image window: one image at 1x and
// one at 2x in the same TIFF, so Finder picks the sharp one on a Retina display.
// Usage: swift scripts/make-dmg-background.swift
// The positions match scripts/dmg/settings.py: Stelix.app centered at (170, 211) and Applications at
// (490, 211), measured from the top left as Finder does. The image is as tall as the window's content
// with Finder's bars off (408 pt); with the tab and path bars on, Finder shows its top 344 pt, so
// everything sits high enough to fit there too.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width: CGFloat = 660
let height: CGFloat = 408
let message = "Drag Stelix into the Applications folder"

func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// Draws the window at `scale` pixels per point. CoreGraphics counts y from the bottom: `flip` turns
/// Finder's top-left coordinates into it.
func render(scale: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    func flip(_ y: CGFloat) -> CGFloat { height - y }

    ctx.setFillColor(hex(0xF2F2F7))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let ink = hex(0x3A3A3C)

    // The sentence, centered on (330, 91).
    let font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    let text = NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: ink])
    let line = CTLineCreateWithAttributedString(text)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    ctx.textPosition = CGPoint(x: (width - lineWidth) / 2, y: flip(91) - (ascent - descent) / 2)
    CTLineDraw(line, ctx)

    // The chevron between the two icons: 22 pt wide, 40 pt tall, centered on (330, 211).
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 330 - 11, y: flip(211 - 20)))
    ctx.addLine(to: CGPoint(x: 330 + 11, y: flip(211)))
    ctx.addLine(to: CGPoint(x: 330 - 11, y: flip(211 + 20)))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, dpi: Int, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(dest, image, properties)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG not written: \(url.path)") }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let work = root.appendingPathComponent("build/dmg-background")
let output = root.appendingPathComponent("scripts/dmg/background.tiff")
let fm = FileManager.default
try? fm.removeItem(at: work)
try fm.createDirectory(at: work, withIntermediateDirectories: true)
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let normal = work.appendingPathComponent("background.png")
let retina = work.appendingPathComponent("background@2x.png")
writePNG(render(scale: 1), dpi: 72, to: normal)
writePNG(render(scale: 2), dpi: 144, to: retina)

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", normal.path, retina.path, "-out", output.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("tiffutil failed") }
print("Wrote \(output.path)")
