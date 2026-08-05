#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.06
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Warm amber / teleprinter paper gradient
    let colors = [
        CGColor(srgbRed: 0.42, green: 0.28, blue: 0.12, alpha: 1),
        CGColor(srgbRed: 0.58, green: 0.40, blue: 0.18, alpha: 1),
        CGColor(srgbRed: 0.72, green: 0.55, blue: 0.28, alpha: 1),
        CGColor(srgbRed: 0.48, green: 0.32, blue: 0.14, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.35, 0.7, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    if let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 1, green: 0.95, blue: 0.8, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }

    // Soft ring
    ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.88, blue: 0.65, alpha: 0.35))
    ctx.setLineWidth(max(1.0, s * 0.014))
    ctx.strokeEllipse(in: rect.insetBy(dx: s * 0.12, dy: s * 0.12))

    ctx.restoreGState()

    // Border
    ctx.setStrokeColor(CGColor(srgbRed: 0.90, green: 0.78, blue: 0.45, alpha: 0.55))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.addPath(path)
    ctx.strokePath()

    drawTapeMark(in: ctx, size: s, bounds: rect)
    return ctx.makeImage()
}

func drawTapeMark(in ctx: CGContext, size s: CGFloat, bounds: CGRect) {
    // Mini punched-tape strip in the icon
    let stripW = bounds.width * 0.72
    let stripH = bounds.height * 0.38
    let stripX = bounds.midX - stripW / 2
    let stripY = bounds.midY - stripH / 2 + s * 0.02
    let stripRect = CGRect(x: stripX, y: stripY, width: stripW, height: stripH)

    ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.89, blue: 0.74, alpha: 0.95))
    let stripPath = CGPath(roundedRect: stripRect, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
    ctx.addPath(stripPath)
    ctx.fillPath()

    // Columns of holes
    let cols = 7
    let rows = 5 // simplified channels + feed in middle
    let colPitch = stripW / CGFloat(cols + 1)
    let rowPitch = stripH / CGFloat(rows + 1)
    let holeR = min(colPitch, rowPitch) * 0.28

    // Pseudo-random but stable punch pattern spelling a friendly shape
    let pattern: [[Bool]] = [
        [true,  false, true,  true,  false, true,  false],
        [false, true,  false, true,  true,  false, true],
        [true,  true,  true,  true,  true,  true,  true], // feed-ish row (all punched smaller)
        [true,  false, true,  false, true,  true,  false],
        [false, true,  true,  false, false, true,  true],
    ]

    for r in 0..<rows {
        for c in 0..<cols {
            let punched = pattern[r][c]
            let cx = stripX + colPitch * CGFloat(c + 1)
            let cy = stripY + rowPitch * CGFloat(r + 1)
            let isFeed = (r == 2)
            let rad = isFeed ? holeR * 0.72 : holeR
            let hole = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
            if punched || isFeed {
                ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.12, blue: 0.06, alpha: 0.82))
                ctx.fillEllipse(in: hole)
            } else {
                ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.15, blue: 0.08, alpha: 0.15))
                ctx.setLineWidth(max(0.5, s * 0.004))
                ctx.strokeEllipse(in: hole)
            }
        }
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Could not write PNG at \(url.path)")
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let realSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in realSizes {
    guard let img = renderIcon(size: px) else {
        fputs("Failed to render \(px)px icon\n", stderr)
        exit(1)
    }
    writePNG(img, to: iconset.appendingPathComponent(name))
}

if let img1024 = renderIcon(size: 1024) {
    writePNG(img1024, to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let icns = assets.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(proc.terminationStatus)
}

print("Wrote \(icns.path)")
