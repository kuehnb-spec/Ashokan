// Builds AppIcon.icns from a square source image (e.g. an AI-generated icon
// with baked-in white corners): crops into the artwork, masks to the macOS
// rounded-rect icon shape on a transparent canvas with standard margins,
// renders every iconset size, and runs iconutil.
//
// Usage: swift scripts/make-icon.swift <source.png>

import AppKit

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: make-icon.swift <source.png>"); exit(1) }
let sourceURL = URL(fileURLWithPath: args[1])
guard let source = NSImage(contentsOf: sourceURL),
      let sourceRep = source.representations.first as? NSBitmapImageRep else {
    print("cannot read \(sourceURL.path)"); exit(1)
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sourceSize = CGFloat(min(sourceRep.pixelsWide, sourceRep.pixelsHigh))
// Crop 8% per side: safely inside the artwork's own drawn squircle,
// past its rounded corners and any baked shadow.
let inset = sourceSize * 0.08
let cropRect = NSRect(x: inset, y: inset, width: sourceSize - inset * 2, height: sourceSize - inset * 2)

func render(_ pixels: Int, to url: URL) {
    let canvas = CGFloat(pixels)
    // Apple icon grid: artwork occupies ~832/1024 of the canvas.
    let artSize = canvas * 832.0 / 1024.0
    let artOrigin = (canvas - artSize) / 2
    let artRect = NSRect(x: artOrigin, y: artOrigin, width: artSize, height: artSize)
    let radius = artSize * 0.2237

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSBezierPath(roundedRect: artRect, xRadius: radius, yRadius: radius).addClip()
    source.draw(in: artRect, from: cropRect, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for size in [16, 32, 128, 256, 512] {
    render(size, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size).png"))
    render(size * 2, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
let icnsURL = root.appendingPathComponent("Ashokan/Resources/AppIcon.icns")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(icnsURL.path)" : "iconutil failed")
exit(task.terminationStatus)
