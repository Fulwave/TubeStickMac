// Renders Resources/AppIcon.icns: a white TV symbol on a blue rounded square.
// Run: swift scripts/make-icon.swift   (the result is committed, so only needed when the design changes)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)   // macOS icon grid
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.92, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.62, alpha: 1))!.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .regular)
    if let sym = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
exit(p.terminationStatus)
