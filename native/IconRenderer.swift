#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: IconRenderer.swift <source.png> <output.png>\n".utf8))
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("Unable to read source icon.\n".utf8))
    exit(65)
}

let canvas = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(70)
}

bitmap.size = NSSize(width: canvas, height: canvas)
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(70) }
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

// The approved logo is a free-standing mark. Preserve its alpha, including
// the centre cutout, instead of baking it into another rounded-square tile.
// Fit the actual artwork rather than the generator's transparent margins, so
// its optical size is consistent with other icons in the Dock.
var sourceRect = NSRect(origin: .zero, size: source.size)
if let representation = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)), representation.hasAlpha {
    var minX = representation.pixelsWide
    var minY = representation.pixelsHigh
    var maxX = 0
    var maxY = 0
    for y in 0..<representation.pixelsHigh {
        for x in 0..<representation.pixelsWide {
            guard let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x + 1)
            maxY = max(maxY, y + 1)
        }
    }
    if maxX > minX, maxY > minY {
        let scaleX = source.size.width / CGFloat(representation.pixelsWide)
        let scaleY = source.size.height / CGFloat(representation.pixelsHigh)
        sourceRect = NSRect(x: CGFloat(minX) * scaleX,
                            y: CGFloat(representation.pixelsHigh - maxY) * scaleY,
                            width: CGFloat(maxX - minX) * scaleX,
                            height: CGFloat(maxY - minY) * scaleY)
    }
}
// Free-standing artwork needs more air than a filled macOS icon tile. Match
// the Dock's neighbouring icons instead of filling their complete tile bounds.
let scale = 800 / max(sourceRect.width, sourceRect.height)
let size = NSSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
let frame = NSRect(x: (CGFloat(canvas) - size.width) / 2,
                   y: (CGFloat(canvas) - size.height) / 2,
                   width: size.width, height: size.height)
source.draw(
    in: frame,
    from: sourceRect,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(70) }
try png.write(to: outputURL, options: .atomic)
