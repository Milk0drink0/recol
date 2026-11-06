// Draws the Recol app icon (the R mark from the deck) as a 1024×1024 PNG.
// usage: swift make-icon.swift out.png
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let brand = NSColor(srgbRed: 0xE2 / 255, green: 0x51 / 255, blue: 0x3A / 255, alpha: 1)
let paper = NSColor(srgbRed: 0xF5 / 255, green: 0xF3 / 255, blue: 0xEF / 255, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body, 100pt margin
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState(); shadow.set()
brand.setFill(); NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()

// paper tile with the R, using the same 100-unit geometry as the web logo (y-down)
let tile = body.insetBy(dx: 120, dy: 120)
let k = tile.width / 100
let t = NSAffineTransform()
t.translateX(by: tile.minX, yBy: tile.maxY)
t.scaleX(by: k, yBy: -k)
t.concat()
paper.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 100, height: 100), xRadius: 18, yRadius: 18).fill()

func part(_ r: NSRect, _ radius: CGFloat, rotate deg: CGFloat = 0, about c: NSPoint = .zero) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    if deg != 0 {
        let rt = AffineTransform(translationByX: c.x, byY: c.y)
        var m = rt; m.rotate(byDegrees: deg); m.translate(x: -c.x, y: -c.y)
        p.transform(using: m)
    }
    p.lineWidth = 6.5; p.lineJoinStyle = .round
    paper.setFill(); p.fill(); brand.setStroke(); p.stroke()
}
part(NSRect(x: 44, y: 36, width: 17, height: 54), 8.5, rotate: -30, about: NSPoint(x: 52.5, y: 43))
part(NSRect(x: 11, y: 30, width: 24, height: 60), 12)
part(NSRect(x: 11, y: 10, width: 78, height: 32), 14)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
