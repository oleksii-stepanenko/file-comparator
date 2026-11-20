// Renders the app icon (Resources/AppIcon.icns). Run: swift Scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824/1024 body with shadow.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.33, green: 0.47, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.47, green: 0.36, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.62, green: 0.30, blue: 0.92, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft top highlight
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    // Two pages
    let pageW = body.width * 0.33, pageH = body.height * 0.56
    let gap = body.width * 0.05
    let top = body.midY + pageH / 2
    let red = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.47, alpha: 1)
    let green = NSColor(srgbRed: 0.30, green: 0.88, blue: 0.55, alpha: 1)
    let white = NSColor.white.withAlphaComponent(0.92)
    let pages: [(CGFloat, [(CGFloat, NSColor, Bool)])] = [
        (body.midX - gap / 2 - pageW, [(0.78, white, false), (0.55, red, true), (0.68, white, false), (0.42, white, false), (0.6, red, true)]),
        (body.midX + gap / 2, [(0.78, white, false), (0.72, green, true), (0.68, white, false), (0.42, white, false), (0.8, green, true)]),
    ]
    for (x, stripes) in pages {
        let r = CGRect(x: x, y: top - pageH, width: pageW, height: pageH)
        let pp = CGPath(roundedRect: r, cornerWidth: pageW * 0.12, cornerHeight: pageW * 0.12, transform: nil)
        ctx.addPath(pp); ctx.setFillColor(NSColor.white.withAlphaComponent(0.17).cgColor); ctx.fillPath()
        ctx.addPath(pp); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(s * 0.004); ctx.strokePath()
        let lineH = pageH * 0.075
        var y = r.maxY - pageH * 0.16
        for (w, c, band) in stripes {
            if band {
                let br = CGRect(x: r.minX + pageW * 0.05, y: y - lineH * 0.55, width: pageW * 0.9, height: lineH * 2.1)
                ctx.addPath(CGPath(roundedRect: br, cornerWidth: lineH * 0.5, cornerHeight: lineH * 0.5, transform: nil))
                ctx.setFillColor(c.withAlphaComponent(0.28).cgColor); ctx.fillPath()
            }
            let lr = CGRect(x: r.minX + pageW * 0.13, y: y, width: pageW * 0.74 * w, height: lineH)
            ctx.addPath(CGPath(roundedRect: lr, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
            ctx.setFillColor(c.cgColor); ctx.fillPath()
            y -= pageH * 0.165
        }
    }
    // Merge arrow badge between the pages
    let d = body.width * 0.17
    let c = CGRect(x: body.midX - d / 2, y: body.minY + body.height * 0.06, width: d, height: d)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: c)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(NSColor(srgbRed: 0.45, green: 0.38, blue: 0.98, alpha: 1).cgColor)
    ctx.setLineWidth(d * 0.1); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let cx = c.midX, cy = c.midY, a = d * 0.22
    ctx.move(to: CGPoint(x: cx - a, y: cy + a * 0.45)); ctx.addLine(to: CGPoint(x: cx + a, y: cy + a * 0.45))
    ctx.move(to: CGPoint(x: cx + a * 0.45, y: cy + a)); ctx.addLine(to: CGPoint(x: cx + a, y: cy + a * 0.45)); ctx.addLine(to: CGPoint(x: cx + a * 0.45, y: cy - a * 0.1))
    ctx.move(to: CGPoint(x: cx + a, y: cy - a * 0.45)); ctx.addLine(to: CGPoint(x: cx - a, y: cy - a * 0.45))
    ctx.move(to: CGPoint(x: cx - a * 0.45, y: cy + a * 0.1)); ctx.addLine(to: CGPoint(x: cx - a, y: cy - a * 0.45)); ctx.addLine(to: CGPoint(x: cx - a * 0.45, y: cy - a))
    ctx.strokePath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(iconset.path)")
