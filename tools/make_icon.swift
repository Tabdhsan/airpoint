// Renders the AirPoint icon artwork with Core Graphics.
//   swift tools/make_icon.swift <out.png> <width> <height> [icon|banner]
// "icon" is a square app icon (no rounded corners; iOS masks it). "banner" is the 16:9 Android TV banner.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = args[1]
let W = CGFloat(Double(args[2])!), H = CGFloat(Double(args[3])!)
let kind = args.count > 4 ? args[4] : "icon"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in a top-left origin.
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

// The artwork lives in a square "stage"; the banner centres it on the left and adds a wordmark.
let S = kind == "banner" ? H : min(W, H)
let ox: CGFloat = kind == "banner" ? H * 0.08 : (W - S) / 2
let oy: CGFloat = (H - S) / 2
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * S, y: oy + y * S) }

// 1. Background: deep indigo → violet diagonal, with a soft glow behind the cursor.
ctx.drawLinearGradient(gradient([(0x0E1030, 1, 0), (0x24164F, 1, 0.55), (0x4A1E78, 1, 1)]),
                       start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
let tip = P(0.47, 0.36)
ctx.drawRadialGradient(gradient([(0x7C5CFF, 0.55, 0), (0x7C5CFF, 0, 1)]),
                       startCenter: tip, startRadius: 0, endCenter: tip, endRadius: S * 0.55, options: [])

// 2. Faint concentric "aim" rings around the tip (laser pointer / click ripple).
for (i, r) in [0.13, 0.21, 0.30].enumerated() {
    ctx.setStrokeColor(color(0xBFA8FF, 0.30 - CGFloat(i) * 0.08))
    ctx.setLineWidth(S * 0.010)
    ctx.strokeEllipse(in: CGRect(x: tip.x - r * S, y: tip.y - r * S, width: 2 * r * S, height: 2 * r * S))
}

// 3. The beam: from the bottom-left corner (where the phone is) into the cursor tip.
let origin = P(-0.05, 1.05)
func beam(width: CGFloat, alpha: CGFloat, blur: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: color(0x29E7FF, alpha))
    let path = CGMutablePath()
    path.move(to: origin)
    path.addLine(to: tip)
    ctx.addPath(path)
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFF4FD8, alpha * 0.2, 0), (0x29E7FF, alpha, 0.6), (0xFFFFFF, alpha, 1)]),
                           start: origin, end: tip, options: [])
    ctx.restoreGState()
}
// Soft glow: blurred, unclipped strokes (a clipped glow shows hard edges).
func glow(width: CGFloat, alpha: CGFloat, blur: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: color(0x29E7FF, alpha))
    ctx.setStrokeColor(color(0x29E7FF, alpha * 0.5))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.move(to: origin)
    ctx.addLine(to: tip)
    ctx.strokePath()
    ctx.restoreGState()
}
glow(width: S * 0.05, alpha: 0.45, blur: S * 0.09)
glow(width: S * 0.025, alpha: 0.7, blur: S * 0.035)
beam(width: S * 0.024, alpha: 1, blur: 0)             // gradient core
beam(width: S * 0.009, alpha: 1, blur: 0)             // hot centre
ctx.saveGState()
ctx.setStrokeColor(color(0xFFFFFF, 0.9))
ctx.setLineWidth(S * 0.006)
ctx.setLineCap(.round)
ctx.move(to: P(0.08, 0.86))
ctx.addLine(to: tip)
ctx.strokePath()
ctx.restoreGState()

// 4. Hot spot where the beam meets the tip.
ctx.drawRadialGradient(gradient([(0xFFFFFF, 1, 0), (0x29E7FF, 0.8, 0.35), (0x29E7FF, 0, 1)]),
                       startCenter: tip, startRadius: 0, endCenter: tip, endRadius: S * 0.07, options: [])

// 5. Cursor arrow, tip at `tip`, with a soft drop shadow.
let a = S * 0.34   // arrow height
let arrow = CGMutablePath()
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 1.0), (0.27, 0.76), (0.45, 1.13), (0.61, 1.05), (0.43, 0.70), (0.78, 0.70)]
arrow.move(to: CGPoint(x: tip.x + pts[0].0 * a, y: tip.y + pts[0].1 * a))
for p in pts.dropFirst() { arrow.addLine(to: CGPoint(x: tip.x + p.0 * a, y: tip.y + p.1 * a)) }
arrow.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: S * 0.018), blur: S * 0.045, color: color(0x05041A, 0.7))
ctx.addPath(arrow)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Subtle top-to-bottom shading inside the arrow so it reads as an object, not a sticker.
ctx.saveGState()
ctx.addPath(arrow)
ctx.clip()
ctx.drawLinearGradient(gradient([(0xFFFFFF, 1, 0), (0xE4DCFF, 1, 1)]),
                       start: tip, end: CGPoint(x: tip.x, y: tip.y + a * 1.13), options: [])
ctx.restoreGState()

ctx.addPath(arrow)
ctx.setStrokeColor(color(0x1A1240, 0.9))
ctx.setLineWidth(S * 0.012)
ctx.setLineJoin(.round)
ctx.strokePath()

// 6. Banner wordmark.
if kind == "banner" {
    let text = NSAttributedString(string: "AirPoint", attributes: [
        .font: NSFont.systemFont(ofSize: H * 0.19, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    NSGraphicsContext.saveGraphicsState()
    ctx.saveGState()
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let size = text.size()
    text.draw(at: CGPoint(x: min(ox + S * 0.86, W - size.width - H * 0.08), y: (H - size.height) / 2))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(Int(W))x\(Int(H))")
