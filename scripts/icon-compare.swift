// Renders masked icon candidates at Dock/Finder sizes on light and dark
// backgrounds so small-size legibility can be judged with eyes, not theory.
// Usage: swift scripts/icon-compare.swift out.png source1.png source2.png ...

import AppKit

let args = CommandLine.arguments
guard args.count > 2 else { print("usage: icon-compare.swift out.png sources..."); exit(1) }
let outURL = URL(fileURLWithPath: args[1])
let sources = args[2...].map { URL(fileURLWithPath: $0) }

let sizes: [CGFloat] = [128, 64, 32, 16]
let cell: CGFloat = 150
let labelH: CGFloat = 24
let rowH = cell + labelH
let width = cell * CGFloat(sizes.count) * 2 + 40
let height = rowH * CGFloat(sources.count) + 20

func maskedDraw(_ image: NSImage, in rect: NSRect) {
    let sourceSize = min(image.size.width, image.size.height)
    let inset = sourceSize * 0.08
    let crop = NSRect(x: inset, y: inset, width: sourceSize - inset * 2, height: sourceSize - inset * 2)
    let radius = rect.width * 0.2237
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.current?.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Light half, dark half.
NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width / 2 + 10, height: height).fill()
NSColor(white: 0.16, alpha: 1).setFill()
NSRect(x: width / 2 + 10, y: 0, width: width / 2, height: height).fill()

for (row, url) in sources.enumerated() {
    guard let image = NSImage(contentsOf: url) else { continue }
    let y = height - rowH * CGFloat(row + 1)
    for half in 0..<2 {
        for (i, size) in sizes.enumerated() {
            let x = 20 + CGFloat(half) * (width / 2) + CGFloat(i) * cell + (cell - size) / 2
            maskedDraw(image, in: NSRect(x: x, y: y + labelH + (cell - size) / 2, width: size, height: size))
            let label = "\(Int(size))px" as NSString
            label.draw(at: NSPoint(x: x + size / 2 - 12, y: y + 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: half == 0 ? NSColor.darkGray : NSColor.lightGray,
            ])
        }
    }
    let name = url.deletingPathExtension().lastPathComponent as NSString
    name.draw(at: NSPoint(x: 22, y: y + rowH - 16), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 12),
        .foregroundColor: NSColor.darkGray,
    ])
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("Wrote \(outURL.path)")
