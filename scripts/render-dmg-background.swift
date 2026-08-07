#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: render-dmg-background.swift <source.png> <background.png> <background@2x.png>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURLs = [
    (URL(fileURLWithPath: CommandLine.arguments[2]), 1),
    (URL(fileURLWithPath: CommandLine.arguments[3]), 2)
]

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to open DMG background source: \(sourceURL.path)\n", stderr)
    exit(1)
}

let canvasSize = CGSize(width: 900, height: 520)
let title = "史上最丝滑贴图生产力工具"
let instruction = "将Pinlume图标拖动到Applications文件夹"

func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    text.draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    )
}

for (outputURL, scale) in outputURLs {
    let scaledSize = CGSize(width: canvasSize.width * CGFloat(scale), height: canvasSize.height * CGFloat(scale))
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(scaledSize.width),
        pixelsHigh: Int(scaledSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Unable to create DMG background canvas\n", stderr)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    sourceImage.draw(in: NSRect(origin: .zero, size: scaledSize))
    let scaleFactor = CGFloat(scale)
    drawCentered(
        title,
        in: NSRect(x: 80 * scaleFactor, y: 440 * scaleFactor, width: 740 * scaleFactor, height: 42 * scaleFactor),
        font: .systemFont(ofSize: 28 * scaleFactor, weight: .semibold),
        color: NSColor(calibratedWhite: 0.16, alpha: 0.92)
    )
    drawCentered(
        instruction,
        in: NSRect(x: 160 * scaleFactor, y: 34 * scaleFactor, width: 580 * scaleFactor, height: 28 * scaleFactor),
        font: .systemFont(ofSize: 18 * scaleFactor, weight: .regular),
        color: NSColor(calibratedWhite: 0.28, alpha: 0.82)
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Unable to encode DMG background PNG\n", stderr)
        exit(1)
    }
    try png.write(to: outputURL, options: .atomic)
}
