// 从 Resources/StatusIcon.svg 生成程序坞图标 Resources/AppIcon.icns。
// 用法：swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let glyph = NSImage(contentsOf: root.appendingPathComponent("Resources/StatusIcon.svg"))!

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS 图标网格：1024 画布里 824×824 的圆角方块。
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = s * 12 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 6 / 1024)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 1))!
        .draw(in: shape, angle: -90)

    // 深色图标
    let g = rect.width * 0.6
    let glyphRect = NSRect(x: rect.midX - g / 2, y: rect.midY - g / 2, width: g, height: g)
    let tinted = NSImage(size: glyphRect.size, flipped: false) { r in
        glyph.draw(in: r)
        NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1).set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: glyphRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "已生成 \(out.path)" : "iconutil 失败")
