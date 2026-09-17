// Draws the placeholder app icon: the brand gradient on Apple's rounded
// tile, with a white note on it.
//
//     swift scripts/make-icon.swift Assets/AppIcon.png
//
// Only a starting point. `scripts/package.sh` uses whatever is at
// `Assets/AppIcon.png`, so a real icon is a 1024×1024 PNG dropped there.

import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let side = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not make a drawing surface")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Apple's icon grid: an 824-point tile centred in 1024, which leaves room
// for the shadow. macOS does not round icons itself, so the corners are
// part of the picture.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// The palette's two colours, pink into red (`Palette.swift`).
let pink = NSColor(srgbRed: 1, green: 78 / 255, blue: 107 / 255, alpha: 1)
let red = NSColor(srgbRed: 1, green: 4 / 255, blue: 54 / 255, alpha: 1)
NSGradient(starting: pink, ending: red)?.draw(in: shape, angle: -45)

let configuration = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let size = note.size
    note.draw(in: NSRect(
        x: tile.midX - size.width / 2,
        y: tile.midY - size.height / 2 + 10,
        width: size.width,
        height: size.height
    ))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the icon")
}
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: url)
print("Wrote \(output)")
