import AppKit

// 640x400 logical window, rendered @2x. Icons will sit at y≈190 from top
// (matches make-dmg.sh): app on the left, Applications on the right.
let W: CGFloat = 1280, H: CGFloat = 800   // 2x of 640x400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx

// Soft background: near-white with a faint emerald wash.
NSGradient(starting: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
           ending:   NSColor(srgbRed: 0.93, green: 0.97, blue: 0.95, alpha: 1))!
    .draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: -90)

func text(_ s: String, _ size: CGFloat, _ color: NSColor, _ y: CGFloat, weight: NSFont.Weight) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let a: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: p]
    let str = NSAttributedString(string: s, attributes: a)
    str.draw(in: CGRect(x: 0, y: y, width: W, height: size * 1.4))
}
// Title + subtitle near the top (y is from the BOTTOM; higher = nearer top).
text("AgentSpend", 60, NSColor(srgbRed: 0.02, green: 0.42, blue: 0.31, alpha: 1),
     H - 150, weight: .bold)
text("Drag the app onto the Applications folder to install",
     30, NSColor(srgbRed: 0.35, green: 0.42, blue: 0.40, alpha: 1), H - 215, weight: .medium)

// Arrow at the icon row (y≈190 from top → 800-190*2 ≈ 420 from bottom center of a 128 icon).
let yc = H - CGFloat(190 * 2) - 128   // vertical center of the icon row, from bottom
let ax0: CGFloat = 520, ax1: CGFloat = 760
let arrow = NSBezierPath()
arrow.lineWidth = 10
arrow.lineCapStyle = .round
arrow.move(to: CGPoint(x: ax0, y: yc)); arrow.line(to: CGPoint(x: ax1, y: yc))
arrow.move(to: CGPoint(x: ax1 - 34, y: yc + 26)); arrow.line(to: CGPoint(x: ax1, y: yc))
arrow.line(to: CGPoint(x: ax1 - 34, y: yc - 26))
NSColor(srgbRed: 0.05, green: 0.59, blue: 0.41, alpha: 0.9).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "assets/dmg-background.png"))
print("wrote assets/dmg-background.png")
