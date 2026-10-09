import AppKit

// The generated metal artwork stays unchanged. AppKit supplies the simple tile
// geometry and system typography so exports have deterministic, clean edges.
let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let branding = root.appendingPathComponent("Resources/Branding")
guard let mark = NSImage(contentsOf: branding.appendingPathComponent("PalladiumMark.png")) else {
    fatalError("Missing PalladiumMark.png")
}

func exportPNG(_ name: String, width: Int, height: Int, draw: () -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create branding canvas")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode branding PNG")
    }
    try data.write(to: branding.appendingPathComponent(name))
}

try exportPNG("PalladiumAppIcon.png", width: 1024, height: 1024) {
    let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904),
        xRadius: 202, yRadius: 202)
    let pearl = NSGradient(colors: [
        NSColor(srgbRed: 0.89, green: 0.89, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 1),
        NSColor(srgbRed: 0.995, green: 0.995, blue: 1, alpha: 1)
    ])!
    pearl.draw(in: tile, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let inset = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900),
        xRadius: 200, yRadius: 200)
    NSColor.white.withAlphaComponent(0.7).setStroke()
    inset.lineWidth = 2
    inset.stroke()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 18
    shadow.set()
    mark.draw(in: NSRect(x: 117, y: 117, width: 790, height: 790),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

let wordmark = NSAttributedString(string: "Palladium", attributes: [
    .font: NSFont.systemFont(ofSize: 100, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.145, green: 0.149, blue: 0.161, alpha: 1),
    .kern: -3
])
try exportPNG("PalladiumWordmark.png", width: Int(ceil(wordmark.size().width)) + 24, height: 144) {
    wordmark.draw(at: NSPoint(x: 12, y: 12))
}
print(branding.path)
