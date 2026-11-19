// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

// Generates App/Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// Draws the icon on a 1024x1024 canvas and scales it to `px`.
func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // Squircle: 824 px of shape on 1024, radius 22.5% of the shape's side.
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let r = 824 * 0.225
    ctx.setFillColor(hex(0x1F1F24))
    ctx.addPath(CGPath(roundedRect: shape, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()

    // Four capsules: 96 wide, 56 apart, centered.
    let colors: [UInt32] = [0xFF375F, 0xFF9F0A, 0x5E5CE6, 0x40C8E0]
    let heights: [CGFloat] = [420, 300, 520, 360]
    let w: CGFloat = 96, gap: CGFloat = 56
    let total = 4 * w + 3 * gap
    var x = (1024 - total) / 2
    for i in 0..<4 {
        let rect = CGRect(x: x, y: (1024 - heights[i]) / 2, width: w, height: heights[i])
        ctx.setFillColor(hex(colors[i]))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        ctx.fillPath()
        x += w + gap
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG not written: \(url.path)") }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("App/Resources/AppIcon.icns")
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Scritto \(output.path)")
