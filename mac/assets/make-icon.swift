import AppKit

// Tweak these four lines to restyle the icon.
let topColor    = NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1) // #34D399 emerald-400
let bottomColor = NSColor(srgbRed: 0.02, green: 0.59, blue: 0.41, alpha: 1) // #059669 emerald-600
let glyphName   = "bolt.fill"   // any SF Symbol
let outPath     = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon-1024.png"

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: the squircle sits inset from the 1024 canvas with a soft shadow.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let radius = tile.width * 0.2237   // Apple's continuous-corner ratio (approx via rounded rect)
let squircle = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.white.setFill(); squircle.fill()
ctx.restoreGState()

// Gradient fill, clipped to the squircle.
ctx.saveGState()
squircle.addClip()
let grad = NSGradient(starting: topColor, ending: bottomColor)!
grad.draw(in: tile, angle: -90)
// subtle top sheen
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.clear])!
    .draw(in: tile, angle: -90)
ctx.restoreGState()

// Centered glyph, tinted white via sourceAtop (masks white to the symbol's
// actual shape rather than its bounding box).
let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .bold)
if let base = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let g = base.size
    let scale = (tile.width * 0.5) / max(g.width, g.height)
    let w = g.width * scale, h = g.height * scale
    let white = NSImage(size: NSSize(width: w, height: h), flipped: false) { rr in
        base.draw(in: rr)
        NSColor.white.set()
        rr.fill(using: .sourceAtop)
        return true
    }
    white.draw(in: CGRect(x: tile.midX - w/2, y: tile.midY - h/2, width: w, height: h))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
