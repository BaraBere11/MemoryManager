#!/usr/bin/env swift
//
// Renders Resources/AppIcon.icns.
//
//   swift Resources/make-icon.swift
//
// Only needs re-running when the artwork changes, so the generated .icns is
// checked in and build.sh just copies it.

import AppKit
import Foundation

// The icon is a donut chart in the same colours the app uses for its breakdown
// bars, so the Dock icon and the window read as the same thing.
let segments: [(fraction: CGFloat, color: NSColor)] = [
    (0.34, NSColor(srgbRed: 0.31, green: 0.51, blue: 0.93, alpha: 1)),  // App Memory blue
    (0.22, NSColor(srgbRed: 0.55, green: 0.40, blue: 0.86, alpha: 1)),  // Wired purple
    (0.15, NSColor(srgbRed: 0.90, green: 0.55, blue: 0.24, alpha: 1)),  // Compressed orange
    (0.12, NSColor(srgbRed: 0.30, green: 0.70, blue: 0.62, alpha: 1)),  // Cached teal
    (0.17, NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.16)),  // Free
]

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Everything below is authored on a 1024 grid and scaled to the target size.
    let scale = CGFloat(pixels) / 1024.0
    context.scaleBy(x: scale, y: scale)

    // Apple's macOS icon grid: an 824pt rounded square centred in a 1024pt canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(
        roundedRect: plate,
        cornerWidth: 185.4,
        cornerHeight: 185.4,
        transform: nil
    )

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.25, green: 0.29, blue: 0.44, alpha: 1).cgColor,
            NSColor(srgbRed: 0.10, green: 0.12, blue: 0.21, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // A hairline rim keeps the plate from dissolving into a dark Dock background.
    context.addPath(platePath)
    context.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
    context.setLineWidth(3)
    context.strokePath()

    let center = CGPoint(x: 512, y: 512)
    let outer: CGFloat = 268
    let inner: CGFloat = 152
    let gap: CGFloat = 0.028  // radians between segments

    var angle: CGFloat = .pi / 2  // start at twelve o'clock, sweep clockwise
    for segment in segments {
        let sweep = segment.fraction * 2 * .pi
        let start = angle - gap / 2
        let end = angle - sweep + gap / 2

        let path = CGMutablePath()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: false)
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(segment.color.cgColor)
        context.fillPath()

        angle -= sweep
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Write the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Each nominal size needs a 1x and a 2x rendering.
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = drawIcon(pixels: pixels)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not encode \(pixels)px")
        }
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", root.appendingPathComponent("Resources/AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
