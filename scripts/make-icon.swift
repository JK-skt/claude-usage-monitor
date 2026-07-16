// Generates the app icon as a full `.iconset` of PNGs using CoreGraphics only
// (no AppKit / no running NSApplication — safe to run headless from CI).
//
// Design: a graphite "squircle" tile with a coral usage-gauge ring at ~72%,
// a cream needle-dot at the arc end, echoing the menu-bar gauge.
//
// Usage: swift make-icon.swift <output.iconset dir>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makeIcon(size: Int) -> CGImage {
    let n = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.clear(CGRect(x: 0, y: 0, width: n, height: n))

    // Rounded tile (macOS squircle proportions ≈ 22.37% corner radius, ~6% margin).
    let margin = n * 0.06
    let side = n - 2 * margin
    let rect = CGRect(x: margin, y: margin, width: side, height: side)
    let radius = side * 0.2237
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Gradient background (graphite).
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.22, green: 0.225, blue: 0.255, alpha: 1),
        CGColor(red: 0.10, green: 0.105, blue: 0.125, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: n), end: CGPoint(x: 0, y: 0), options: [])
    // Soft top sheen.
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: n),
                           end: CGPoint(x: 0, y: n * 0.55), options: [])
    ctx.restoreGState()

    // Gauge ring.
    let center = CGPoint(x: n / 2, y: n / 2)
    let ringRadius = side * 0.30
    let lineW = side * 0.115
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineW)

    // Track.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Progress arc (~72%) starting at top, going clockwise. In CG, +y is up so top = π/2.
    let start = CGFloat.pi / 2
    let fraction: CGFloat = 0.72
    let end = start - fraction * .pi * 2
    ctx.setStrokeColor(CGColor(red: 0.80, green: 0.47, blue: 0.36, alpha: 1)) // coral
    ctx.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()

    // Needle dot at the arc end.
    let dot = CGPoint(x: center.x + ringRadius * cos(end), y: center.y + ringRadius * sin(end))
    ctx.setFillColor(CGColor(red: 0.96, green: 0.92, blue: 0.87, alpha: 1))
    let dr = lineW * 0.44
    ctx.fillEllipse(in: CGRect(x: dot.x - dr, y: dot.y - dr, width: dr * 2, height: dr * 2))

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("Failed to write \(url.path)") }
}

// --- main ---
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.iconset dir>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (base size, @-scale filename) pairs required by iconutil.
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in variants {
    writePNG(makeIcon(size: size), to: outDir.appendingPathComponent(name))
}
print("Wrote \(variants.count) PNGs to \(outDir.path)")
