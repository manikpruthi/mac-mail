// Renders Resources/AppIcon.icns: a blue rounded square with a white envelope and a lightning notch.
// Run: swift tools/make_icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.24, green: 0.56, blue: 1.0, alpha: 1), NSColor(red: 0.10, green: 0.32, blue: 0.86, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // Envelope body
    let env = NSRect(x: 230 * s, y: 320 * s, width: 564 * s, height: 390 * s)
    let body = NSBezierPath(roundedRect: env, xRadius: 48 * s, yRadius: 48 * s)
    NSColor.white.setFill()
    body.fill()
    // Flap
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: env.minX + 30 * s, y: env.maxY - 20 * s))
    flap.line(to: NSPoint(x: env.midX, y: env.midY - 10 * s))
    flap.line(to: NSPoint(x: env.maxX - 30 * s, y: env.maxY - 20 * s))
    flap.lineWidth = 34 * s
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    NSColor(red: 0.13, green: 0.40, blue: 0.92, alpha: 1).setStroke()
    flap.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try! render(512).write(to: URL(fileURLWithPath: "docs/screenshots/icon.png"))
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
