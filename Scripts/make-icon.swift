#!/usr/bin/env swift
// Generates an iconset for Tango.app at all standard macOS icon sizes.
// Run via Scripts/make-icon.sh which then calls iconutil to produce AppIcon.icns.

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: make-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}
let outDir = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Standard Apple icon sizes for .iconset → .icns (each pair = 1x and 2x).
let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(pixels: CGFloat) -> Data? {
    let size = NSSize(width: pixels, height: pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixels),
        pixelsHigh: Int(pixels),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { return nil }
    bitmap.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

    // Use a superellipse (squircle) clip — the macOS Big Sur+ icon shape.
    let inset = pixels * 0.04
    let rect = CGRect(x: inset, y: inset, width: pixels - 2*inset, height: pixels - 2*inset)
    let cornerRadius = (pixels - 2*inset) * 0.225  // Apple uses ~22.5% corner
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Background: warm tango gradient — deep red to orange diagonal.
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.78, green: 0.10, blue: 0.20, alpha: 1.0),  // deep red
        CGColor(red: 0.95, green: 0.45, blue: 0.10, alpha: 1.0)   // orange
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: pixels),
            end: CGPoint(x: pixels, y: 0),
            options: []
        )
    }

    // Subtle inner highlight at top
    if let highlight = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(highlight, start: CGPoint(x: 0, y: pixels), end: CGPoint(x: 0, y: pixels * 0.5), options: [])
    }

    // Foreground glyph: SF Symbol "hand.tap.fill" rendered in white.
    let glyphHeight = pixels * 0.55
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: glyphHeight, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
    if let glyph = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let g = glyph
        let glyphSize = g.size
        // Scale to target glyphHeight while preserving aspect
        let scale = glyphHeight / glyphSize.height
        let drawSize = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
        let origin = NSPoint(
            x: (pixels - drawSize.width) / 2,
            y: (pixels - drawSize.height) / 2 - pixels * 0.02   // nudge slightly down
        )
        // Drop shadow for legibility on small sizes
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -pixels * 0.01), blur: pixels * 0.02, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        g.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()
    }

    return bitmap.representation(using: .png, properties: [:])
}

for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        fputs("failed to render \(name)\n", stderr)
        exit(2)
    }
    let url = outDir.appendingPathComponent(name)
    try data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(Int(pixels))px)")
}
