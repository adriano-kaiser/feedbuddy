// Draws the app icon (purple rounded square with an RSS glyph) and writes an .icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the tile sits inside ~10% padding.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let gradient = NSGradient(starting: NSColor(red: 0.55, green: 0.42, blue: 1.0, alpha: 1),
                              ending: NSColor(red: 0.42, green: 0.28, blue: 0.92, alpha: 1))!
    gradient.draw(in: NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225), angle: -90)

    // RSS glyph: dot + two arcs from the lower-left corner of the tile.
    let w = tile.width
    let center = NSPoint(x: tile.minX + w * 0.28, y: tile.minY + w * 0.28)
    NSColor.white.setFill()
    NSColor.white.setStroke()
    let r = w * 0.075
    NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
    for radius in [0.3, 0.52] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: w * radius, startAngle: 90, endAngle: 0, clockwise: true)
        arc.lineWidth = w * 0.09
        arc.lineCapStyle = .round
        arc.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
