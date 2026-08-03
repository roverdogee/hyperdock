#!/usr/bin/env swift
import AppKit

let canvas = 1024.0
let plate = 824.0
let inset = (canvas - plate) / 2

func squirclePath(in rect: CGRect) -> CGPath {
    let r = rect.width * 0.2237
    let c = r * 0.6667
    let p = CGMutablePath()
    let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
    p.move(to: CGPoint(x: x + r, y: y))
    p.addLine(to: CGPoint(x: x + w - r, y: y))
    p.addCurve(to: CGPoint(x: x + w, y: y + r),
               control1: CGPoint(x: x + w - r + c, y: y),
               control2: CGPoint(x: x + w, y: y + r - c))
    p.addLine(to: CGPoint(x: x + w, y: y + h - r))
    p.addCurve(to: CGPoint(x: x + w - r, y: y + h),
               control1: CGPoint(x: x + w, y: y + h - r + c),
               control2: CGPoint(x: x + w - r + c, y: y + h))
    p.addLine(to: CGPoint(x: x + r, y: y + h))
    p.addCurve(to: CGPoint(x: x, y: y + h - r),
               control1: CGPoint(x: x + r - c, y: y + h),
               control2: CGPoint(x: x, y: y + h - r + c))
    p.addLine(to: CGPoint(x: x, y: y + r))
    p.addCurve(to: CGPoint(x: x + r, y: y),
               control1: CGPoint(x: x, y: y + r - c),
               control2: CGPoint(x: x + r - c, y: y))
    p.closeSubpath()
    return p
}

func rounded(_ rect: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(into context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
    let shape = squirclePath(in: plateRect)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [CGColor(srgbRed: 0.30, green: 0.55, blue: 1.00, alpha: 1),
                                       CGColor(srgbRed: 0.13, green: 0.24, blue: 0.72, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: canvas),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    let sheen = CGGradient(colorsSpace: space,
                           colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(sheen,
                               start: CGPoint(x: 0, y: canvas - inset),
                               end: CGPoint(x: 0, y: canvas * 0.52),
                               options: [])
    context.restoreGState()

    let dockHeight = 84.0
    let dockRect = CGRect(x: inset + 118, y: inset + 96, width: plate - 236, height: dockHeight)
    context.saveGState()
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24))
    context.addPath(rounded(dockRect, dockHeight / 2))
    context.fillPath()
    let tile = 46.0
    for (i, x) in [dockRect.midX - 96, dockRect.midX, dockRect.midX + 96].enumerated() {
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: i == 1 ? 0.95 : 0.45))
        context.addPath(rounded(CGRect(x: x - tile / 2, y: dockRect.midY - tile / 2,
                                       width: tile, height: tile), 12))
        context.fillPath()
    }
    context.restoreGState()

    let bubbleRect = CGRect(x: inset + 74, y: inset + 268, width: plate - 148, height: 330)
    let pointer = 54.0
    let bubble = CGMutablePath()
    bubble.addPath(rounded(bubbleRect, 62))
    bubble.move(to: CGPoint(x: bubbleRect.midX - pointer / 2, y: bubbleRect.minY + 6))
    bubble.addLine(to: CGPoint(x: bubbleRect.midX, y: bubbleRect.minY - pointer * 0.62))
    bubble.addLine(to: CGPoint(x: bubbleRect.midX + pointer / 2, y: bubbleRect.minY + 6))
    bubble.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
                      color: CGColor(srgbRed: 0, green: 0.05, blue: 0.25, alpha: 0.45))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97))
    context.addPath(bubble)
    context.fillPath()
    context.restoreGState()

    let cardGap = 34.0
    let cardInset = 46.0
    let cardWidth = (bubbleRect.width - cardInset * 2 - cardGap) / 2
    let cardHeight = bubbleRect.height - cardInset * 2
    for i in 0..<2 {
        let x = bubbleRect.minX + cardInset + Double(i) * (cardWidth + cardGap)
        let card = CGRect(x: x, y: bubbleRect.minY + cardInset,
                          width: cardWidth, height: cardHeight)
        context.setFillColor(CGColor(srgbRed: 0.86, green: 0.90, blue: 0.98, alpha: 1))
        context.addPath(rounded(card, 22))
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.24, green: 0.44, blue: 0.92, alpha: 1))
        context.addPath(rounded(CGRect(x: card.minX, y: card.maxY - 40,
                                       width: card.width, height: 40), 14))
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.86, green: 0.90, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: card.minX, y: card.maxY - 40, width: card.width, height: 14))
    }
}

func render(size: Double) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: size / canvas, y: size / canvas)
    draw(into: cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let entries: [(String, Double)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in entries {
    let rep = render(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}
print("wrote \(entries.count) images to \(out)")
