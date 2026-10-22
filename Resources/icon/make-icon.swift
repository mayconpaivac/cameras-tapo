// Draws the app icon (1024×1024 PNG). Run: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locs)!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

// MARK: Background tile (macOS icon grid: 824pt tile, 100pt margin)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0x0B1B3A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x3A8DFF), color(0x1747B8), color(0x0B1B4A)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft glow behind the camera.
ctx.drawRadialGradient(gradient([color(0x8FD3FF, 0.55), color(0x8FD3FF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
// Signal waves, top right.
ctx.setLineCap(.round)
for (i, r) in [70.0, 120.0, 170.0].enumerated() {
    ctx.setStrokeColor(color(0xFFFFFF, 0.55 - Double(i) * 0.13))
    ctx.setLineWidth(26)
    ctx.addArc(center: CGPoint(x: 690, y: 690), radius: r, startAngle: .pi * 0.05, endAngle: .pi * 0.45, clockwise: false)
    ctx.strokePath()
}
ctx.restoreGState()

// MARK: Camera base (pan/tilt stand)
let base = CGRect(x: 512 - 190, y: 190, width: 380, height: 110)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(CGPath(roundedRect: base, cornerWidth: 55, cornerHeight: 55, transform: nil))
ctx.setFillColor(color(0xF2F5FA)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: base, cornerWidth: 55, cornerHeight: 55, transform: nil)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xC9D3E3)], [0, 1]),
                       start: CGPoint(x: 512, y: 300), end: CGPoint(x: 512, y: 190), options: [])
ctx.restoreGState()
// Neck.
let neck = CGRect(x: 512 - 110, y: 260, width: 220, height: 90)
ctx.addPath(CGPath(roundedRect: neck, cornerWidth: 40, cornerHeight: 40, transform: nil))
ctx.setFillColor(color(0xDCE3EE)); ctx.fillPath()

// MARK: Camera head (sphere)
let head = CGPoint(x: 512, y: 560)
let headR: CGFloat = 245
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x000000, 0.40))
ctx.addPath(circle(head, headR)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(circle(head, headR)); ctx.clip()
ctx.drawRadialGradient(gradient([color(0xFFFFFF), color(0xEEF2F8), color(0xB9C5D8)], [0, 0.55, 1]),
                       startCenter: CGPoint(x: head.x - 80, y: head.y + 110), startRadius: 0,
                       endCenter: head, endRadius: headR, options: [.drawsAfterEndLocation])
ctx.restoreGState()

// Dark face plate.
let face = CGPoint(x: 512, y: 540)
ctx.addPath(circle(face, 168)); ctx.setFillColor(color(0x0E1424)); ctx.fillPath()
ctx.saveGState()
ctx.addPath(circle(face, 168)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x2A3550), color(0x0A0F1C)], [0, 1]),
                       start: CGPoint(x: 512, y: 708), end: CGPoint(x: 512, y: 372), options: [])
ctx.restoreGState()

// Lens: outer ring, glass, iris, highlights.
ctx.addPath(circle(face, 108)); ctx.setFillColor(color(0x1B2235)); ctx.fillPath()
ctx.setStrokeColor(color(0x55617D, 0.9)); ctx.setLineWidth(6); ctx.addPath(circle(face, 108)); ctx.strokePath()
ctx.saveGState()
ctx.addPath(circle(face, 84)); ctx.clip()
ctx.drawRadialGradient(gradient([color(0x6FE3FF), color(0x2563EB), color(0x231A5E), color(0x05060F)], [0, 0.3, 0.7, 1]),
                       startCenter: CGPoint(x: face.x + 18, y: face.y - 18), startRadius: 0,
                       endCenter: face, endRadius: 84, options: [])
ctx.restoreGState()
ctx.addPath(circle(face, 30)); ctx.setFillColor(color(0x03040A, 0.85)); ctx.fillPath()
ctx.addPath(circle(CGPoint(x: face.x - 32, y: face.y + 34), 20)); ctx.setFillColor(color(0xFFFFFF, 0.85)); ctx.fillPath()
ctx.addPath(circle(CGPoint(x: face.x + 30, y: face.y - 36), 8)); ctx.setFillColor(color(0xFFFFFF, 0.45)); ctx.fillPath()

// Status LED.
let led = CGPoint(x: 512, y: 672)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: color(0x34F58A, 0.9))
ctx.addPath(circle(led, 12)); ctx.setFillColor(color(0x34F58A)); ctx.fillPath()
ctx.restoreGState()

// Glossy highlight on the sphere.
ctx.saveGState()
ctx.addPath(circle(head, headR)); ctx.clip()
ctx.addPath(CGPath(ellipseIn: CGRect(x: 330, y: 690, width: 250, height: 90), transform: nil))
ctx.setFillColor(color(0xFFFFFF, 0.55)); ctx.fillPath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok \(out)")
