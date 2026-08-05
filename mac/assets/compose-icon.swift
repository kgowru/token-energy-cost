import AppKit

// Masks a square source image into the macOS app-icon tile: inset squircle with
// a soft shadow. `zoom` enlarges the art within the tile (the source has generous
// padding; >1 crops the uniform background edges, which the squircle hides anyway).
let inPath  = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/agent-spend-icon-src.jpg"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/icon-1024.png"
let zoom: CGFloat = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3])!) : 1.20

guard let src = NSImage(contentsOfFile: inPath) else { fatalError("cannot load \(inPath)") }

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let radius = tile.width * 0.2237
let squircle = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Shadow (cast by the squircle silhouette).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.white.setFill(); squircle.fill()
ctx.restoreGState()

// Clip to the squircle, draw the source aspect-filled (+zoom), centered.
ctx.saveGState()
squircle.addClip()
let side = tile.width * zoom
let r = CGRect(x: tile.midX - side/2, y: tile.midY - side/2, width: side, height: side)
src.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0,
         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (zoom \(zoom))")
