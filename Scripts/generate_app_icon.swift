#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconVariant {
    let filename: String
    let pixels: Int
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1_024)
]

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_app_icon.swift OUTPUT_DIRECTORY\n", stderr)
    exit(64)
}

private let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

private func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
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
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let scale = CGFloat(pixels) / 1_024
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let tile = CGRect(x: 68, y: 68, width: 888, height: 888)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 210, cornerHeight: 210, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 34, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.14, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let colors = [
        NSColor(calibratedRed: 0.035, green: 0.42, blue: 0.72, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.09, blue: 0.19, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 120, y: 920), end: CGPoint(x: 900, y: 100), options: [])

    let glowColors = [
        NSColor(calibratedRed: 0.0, green: 0.92, blue: 0.83, alpha: 0.34).cgColor,
        NSColor.clear.cgColor
    ] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 770, y: 730), startRadius: 0, endCenter: CGPoint(x: 770, y: 730), endRadius: 470, options: [])
    context.restoreGState()

    let pipeline = CGMutablePath()
    pipeline.move(to: CGPoint(x: 226, y: 512))
    pipeline.addLine(to: CGPoint(x: 452, y: 512))
    pipeline.move(to: CGPoint(x: 452, y: 512))
    pipeline.addCurve(to: CGPoint(x: 754, y: 735), control1: CGPoint(x: 570, y: 512), control2: CGPoint(x: 578, y: 735))
    pipeline.move(to: CGPoint(x: 452, y: 512))
    pipeline.addLine(to: CGPoint(x: 754, y: 512))
    pipeline.move(to: CGPoint(x: 452, y: 512))
    pipeline.addCurve(to: CGPoint(x: 754, y: 289), control1: CGPoint(x: 570, y: 512), control2: CGPoint(x: 578, y: 289))

    context.saveGState()
    context.addPath(pipeline)
    context.setLineWidth(72)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.24).cgColor)
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.strokePath()
    context.restoreGState()

    context.addPath(pipeline)
    context.setLineWidth(48)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.strokePath()

    let nodeCenters = [
        CGPoint(x: 226, y: 512),
        CGPoint(x: 754, y: 289),
        CGPoint(x: 754, y: 512),
        CGPoint(x: 754, y: 735)
    ]
    for (index, center) in nodeCenters.enumerated() {
        let radius: CGFloat = index == 0 ? 65 : 58
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor((index == 0
            ? NSColor(calibratedRed: 0.08, green: 0.68, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.04, green: 0.88, blue: 0.65, alpha: 1)).cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(22)
        context.strokeEllipse(in: rect.insetBy(dx: 11, dy: 11))
    }

    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(24)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 716, y: 730))
    context.addLine(to: CGPoint(x: 747, y: 699))
    context.addLine(to: CGPoint(x: 800, y: 760))
    context.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for variant in variants {
    let data = try renderIcon(pixels: variant.pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename), options: .atomic)
}
