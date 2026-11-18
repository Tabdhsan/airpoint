import Combine
import SwiftUI
import UIKit

// MARK: - Chaos Zine
//
// A photocopied, sticker-bombed riso zine. Buttons are torn stickers with a misregistered
// second ink layer; the pad is cutting-mat paper with a two-colour scribble trail; marker
// notes everywhere. The mess is surface only: every face fills its fixed box, tilt is visual,
// and Reduce Motion turns off tilt, wobble and bursts while keeping the colours.
//
// Easter eggs (state lives in `ZineState.shared`):
//  - CHAOS MODE: scribble left-right hard on the pad (6+ direction reversals within 1s).
//  - Unhinged status: tap the status line repeatedly; it escalates, then calms down by itself.
//  - Bad registration: tap the status dot 5 times quickly; the ink layers slide out of register.
//  - Clicky: after 100 clicks a critter moves into the corner between the strips.

struct ZineSkin: RemoteSkin {
    var colorScheme: ColorScheme? { nil }
    var tint: Color { ZInk.tint }
    var ink: Color { ZInk.ink }
    var inkSecondary: Color { ZInk.inkSoft }
    var titleFont: Font { .custom(ZFont.hand, size: 25, relativeTo: .title2) }
    var captionFont: Font { .custom(ZFont.mono, size: 12, relativeTo: .caption) }

    func backdrop() -> AnyView { AnyView(ZBackdrop()) }
    func button(_ b: SkinButton, pressed: Bool) -> AnyView { AnyView(ZStickerFace(b: b, pressed: pressed)) }
    func pad(_ s: PadState) -> AnyView { AnyView(ZPadView(s: s)) }
    func strip(vertical: Bool, _ s: StripState) -> AnyView { AnyView(ZStripView(vertical: vertical, s: s)) }
    func speedControl(value: Binding<Double>, range: ClosedRange<Double>) -> AnyView {
        AnyView(ZSpeed(value: value, range: range))
    }
    func statusDot(connected: Bool) -> AnyView { AnyView(ZDot(connected: connected)) }
    func subtitle(status: String) -> AnyView { AnyView(ZSubtitle(status: status)) }
    func gear(pressed: Bool) -> AnyView { AnyView(ZGear(pressed: pressed)) }
    func effects() -> AnyView { AnyView(ZEffectsHost()) }
}

// MARK: - Palette, fonts, randomness

private func zHex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
    UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}
private func zDyn(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
}

private enum ZInk {
    // Riso inks: constant across appearances.
    static let pink = Color(zHex(0xff48b0))
    static let blue = Color(zHex(0x0078bf))
    static let yellow = Color(zHex(0xffe800))
    static let orange = Color(zHex(0xff6c2f))
    static let teal = Color(zHex(0x00a3a3))
    static let violet = Color(zHex(0x765ba7))
    static let green = Color(zHex(0x2fbf5b))
    static let trailBlue = Color(zHex(0x00a3ff))
    static let sticker = Color(zHex(0x1a1633))
    static let all: [Color] = [pink, blue, yellow, orange, teal, violet]

    // Paper: blue-grey photocopy on a cutting mat (light), deep indigo with a pink grid (dark).
    static let page = zDyn(zHex(0xd3dee1), zHex(0x15112f))
    static let gridMinor = zDyn(zHex(0x0078bf, 0.13), zHex(0xff48b0, 0.10))
    static let gridMajor = zDyn(zHex(0x0078bf, 0.26), zHex(0xff48b0, 0.22))
    static let halftone = zDyn(zHex(0x1a1633, 0.06), zHex(0xf1eeff, 0.05))
    static let pad = zDyn(zHex(0xf3f7f8), zHex(0x262058))
    static let padGrid = zDyn(zHex(0x0078bf, 0.20), zHex(0xff48b0, 0.22))
    static let ink = zDyn(zHex(0x1a1633), zHex(0xf1eeff))
    static let inkSoft = zDyn(zHex(0x4b4868), zHex(0xb9b3de))
    static let shadow = zDyn(zHex(0x1a1633, 0.5), zHex(0x000000, 0.65))
    static let peel = zDyn(zHex(0xffffff), zHex(0xe4e0f6))
    static let peel2 = zDyn(zHex(0xc7c9da), zHex(0x8d86b8))
    static let tint = zDyn(zHex(0x0078bf), zHex(0xff48b0))
    // Text-safe versions of the inks on paper.
    static let pinkText = zDyn(zHex(0xd0167f), zHex(0xff6cc1))
    static let blueText = zDyn(zHex(0x0067a6), zHex(0x5cb8ff))
    static let violetText = zDyn(zHex(0x664c97), zHex(0xb9a2ff))
    static let orangeText = zDyn(zHex(0xc4460f), zHex(0xff9466))
}

private enum ZInkKey: Int, CaseIterable {
    case pink, blue, yellow, orange, teal, violet
    var fill: Color { ZInk.all[rawValue] }
    /// The second, misregistered ink layer.
    var ghost: Color {
        switch self {
        case .pink, .orange: return ZInk.blue
        case .violet: return ZInk.yellow
        default: return ZInk.pink
        }
    }
    var text: Color { self == .blue || self == .violet ? .white : ZInk.sticker }
}

private enum ZFont {
    static let display = "BowlbyOne-Regular"
    static let hand = "PermanentMarker-Regular"
    static let mono = "SpaceMono-Regular"
    static let monoBold = "SpaceMono-Bold"
    static func display(_ s: CGFloat) -> Font { .custom(display, fixedSize: s) }
    static func hand(_ s: CGFloat) -> Font { .custom(hand, fixedSize: s) }
}

/// Deterministic randomness so a sticker keeps its tear and tilt between renders.
private struct ZRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed ^ 0x2545F4914F6CDD1D }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

private func zSeed(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    return h
}

private enum ZTiles {
    /// 6pt halftone tile for sticker paper.
    static let stickerDots: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6)).image { c in
            zHex(0x1a1633, 0.16).setFill()
            c.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 2.2, height: 2.2))
        }
    }()
}

private struct ZHalftone: View {
    var body: some View {
        Image(uiImage: ZTiles.stickerDots).resizable(resizingMode: .tile)
    }
}

// MARK: - Shared easter-egg state

private final class ZineState: ObservableObject {
    static let shared = ZineState()

    @Published private(set) var chaos = false
    @Published private(set) var shuffle = 0
    @Published private(set) var misreg = false
    /// Fires on each chaos tick so the effects layer can drop confetti.
    let confetti = PassthroughSubject<Int, Never>()
    /// Burst requests in global coordinates.
    let burstAt = PassthroughSubject<CGPoint, Never>()

    // Bookkeeping (not published; read when an event arrives).
    var lastPadPoint: CGPoint?
    var lastPadDown = Date.distantPast
    var lastStrip: (vertical: Bool, at: Date)?
    var lastButton: (id: String, at: Date)?
    var reduceMotion = false

    private var reversals: [TimeInterval] = []
    private var lastSign: CGFloat = 0
    private var chaosTimer: Timer?
    private var chaosEnd: DispatchWorkItem?
    private var misregEnd: DispatchWorkItem?
    private var dotTaps: [Date] = []

    /// Counts direction reversals of pad strokes; 6 within a second sets off CHAOS MODE.
    func noteMove(dx: CGFloat) {
        guard abs(dx) >= 3 else { return }
        let sign: CGFloat = dx > 0 ? 1 : -1
        let now = CACurrentMediaTime()
        if lastSign != 0 && sign != lastSign {
            reversals.append(now)
            reversals.removeAll { now - $0 > 1 }
            if reversals.count >= 6 {
                reversals = []
                startChaos()
            }
        }
        lastSign = sign
    }

    func startChaos() {
        guard !chaos else { return }
        chaos = true
        shuffle &+= 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        var n = 0
        chaosTimer?.invalidate()
        if !reduceMotion {
            chaosTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] _ in
                guard let self else { return }
                n += 1
                if n % 2 == 0 { self.shuffle &+= 1 }
                self.confetti.send(n)
            }
        }
        chaosEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.endChaos() }
        chaosEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: end)
    }

    func endChaos() {
        chaosTimer?.invalidate()
        chaosTimer = nil
        chaos = false
    }

    /// Five quick taps on the status dot slide the ink layers out of register.
    func tapDot() {
        let now = Date()
        dotTaps = dotTaps.filter { now.timeIntervalSince($0) < 2.2 } + [now]
        Haptics.tick()
        guard dotTaps.count >= 5 else { return }
        dotTaps = []
        misreg = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        misregEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.misreg = false }
        misregEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: end)
    }
}

/// Global frames of surfaces the effects layer anchors to.
private final class ZFrames: ObservableObject {
    static let shared = ZFrames()
    @Published var pad: CGRect = .zero
    @Published var vstrip: CGRect = .zero
    @Published var hstrip: CGRect = .zero
    @Published var ok: CGRect = .zero

    func set(_ key: ReferenceWritableKeyPath<ZFrames, CGRect>, _ r: CGRect) {
        if self[keyPath: key] != r { self[keyPath: key] = r }
    }
}

// MARK: - Shapes

/// Torn sticker edge with an optional peeled corner (0 tl, 1 tr, 2 br, 3 bl, -1 none).
private struct ZTorn: Shape {
    var seed: UInt64
    var corner: Int = -1
    var teeth: Int = 8
    var amp: CGFloat = 2.8
    var cut: CGFloat = 12

    func path(in r: CGRect) -> Path {
        var g = ZRNG(seed)
        func j() -> CGFloat { g.range(0, amp) }
        let n = max(teeth, 4), w = r.width, h = r.height
        var p = Path()
        if corner == 0 {
            p.move(to: CGPoint(x: r.minX, y: r.minY + cut)); p.addLine(to: CGPoint(x: r.minX + cut, y: r.minY))
        } else { p.move(to: CGPoint(x: r.minX, y: r.minY)) }
        for i in 2...(n - 2) { p.addLine(to: CGPoint(x: r.minX + w * CGFloat(i) / CGFloat(n), y: r.minY + j())) }
        if corner == 1 {
            p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut))
        } else { p.addLine(to: CGPoint(x: r.maxX, y: r.minY)) }
        for i in 2...(n - 2) { p.addLine(to: CGPoint(x: r.maxX - j(), y: r.minY + h * CGFloat(i) / CGFloat(n))) }
        if corner == 2 {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cut)); p.addLine(to: CGPoint(x: r.maxX - cut, y: r.maxY))
        } else { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
        for i in stride(from: n - 2, through: 2, by: -1) {
            p.addLine(to: CGPoint(x: r.minX + w * CGFloat(i) / CGFloat(n), y: r.maxY - j()))
        }
        if corner == 3 {
            p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cut))
        } else { p.addLine(to: CGPoint(x: r.minX, y: r.maxY)) }
        for i in stride(from: n - 2, through: 2, by: -1) {
            p.addLine(to: CGPoint(x: r.minX + j(), y: r.minY + h * CGFloat(i) / CGFloat(n)))
        }
        p.closeSubpath()
        return p
    }
}

/// The folded-back flap of a peeled corner.
private struct ZPeel: Shape {
    var corner: Int
    var cut: CGFloat = 12
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c: CGPoint, a: CGPoint, b: CGPoint
        switch corner {
        case 0: c = CGPoint(x: r.minX, y: r.minY); a = CGPoint(x: r.minX + cut, y: r.minY); b = CGPoint(x: r.minX, y: r.minY + cut)
        case 1: c = CGPoint(x: r.maxX, y: r.minY); a = CGPoint(x: r.maxX - cut, y: r.minY); b = CGPoint(x: r.maxX, y: r.minY + cut)
        case 2: c = CGPoint(x: r.maxX, y: r.maxY); a = CGPoint(x: r.maxX - cut, y: r.maxY); b = CGPoint(x: r.maxX, y: r.maxY - cut)
        case 3: c = CGPoint(x: r.minX, y: r.maxY); a = CGPoint(x: r.minX + cut, y: r.maxY); b = CGPoint(x: r.minX, y: r.maxY - cut)
        default: return p
        }
        p.move(to: a)
        p.addLine(to: CGPoint(x: a.x + b.x - c.x, y: a.y + b.y - c.y))
        p.addLine(to: b)
        p.closeSubpath()
        return p
    }
}

/// Wobbly hand-cut circle.
private struct ZBlob: Shape {
    var seed: UInt64
    var wobble: CGFloat = 0.06
    func path(in r: CGRect) -> Path {
        var g = ZRNG(seed)
        let n = 14
        let pts: [CGPoint] = (0..<n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let k = 1 + g.range(-wobble, wobble)
            return CGPoint(x: r.midX + cos(a) * r.width / 2 * k, y: r.midY + sin(a) * r.height / 2 * k)
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var p = Path()
        p.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n { p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i]) }
        p.closeSubpath()
        return p
    }
}

private struct ZStar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2, rr = R * 0.45
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let rad = i % 2 == 0 ? R : rr
            let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Marker scribble across a rect (the speed track).
private struct ZScribble: Shape {
    var seed: UInt64 = 42
    var passes = 1
    func path(in r: CGRect) -> Path {
        var g = ZRNG(seed)
        var p = Path()
        for pass in 0..<passes {
            let yOff: CGFloat = pass == 0 ? 0 : 3
            var x = r.minX
            p.move(to: CGPoint(x: x, y: r.midY + yOff))
            while x < r.maxX {
                x = min(r.maxX, x + 7)
                let y = r.midY + yOff + sin(x / 12 + CGFloat(pass) * 2) * 2.6 + g.range(-0.8, 0.8)
                p.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return p
    }
}

/// Hand-drawn loop around the OK label (from the prototype's SVG, 112x72 box).
private struct ZRing: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 112 * r.width, y: r.minY + y / 72 * r.height) }
        var p = Path()
        p.move(to: pt(60, 6))
        p.addCurve(to: pt(10, 44), control1: pt(22, 2), control2: pt(4, 22))
        p.addCurve(to: pt(98, 52), control1: pt(16, 66), control2: pt(74, 72))
        p.addCurve(to: pt(64, 8), control1: pt(116, 36), control2: pt(104, 8))
        p.addCurve(to: pt(34, 16), control1: pt(52, 8), control2: pt(40, 12))
        return p
    }
}

/// Washi tape with nibbled ends.
private struct ZWashi: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.08), (0.06, 0), (0.12, 0.1), (0.18, 0), (1, 0), (0.94, 0.5), (1, 1), (0, 1), (0.05, 0.55)]
        var p = Path()
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: r.minX + q.0 * r.width, y: r.minY + q.1 * r.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Doodles for click bursts, in a 22x22 box.
private enum ZDoodle {
    static let paths: [Path] = {
        func P(_ pts: [(CGFloat, CGFloat)], close: Bool) -> Path {
            var p = Path()
            p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
            if close { p.closeSubpath() }
            return p
        }
        let star = P([(11, 1), (13.5, 8), (21, 8.5), (15, 13), (17, 21), (11, 16.5), (5, 21), (7, 13), (1, 8.5), (8.5, 8)], close: true)
        var spiral = Path()
        for t in 0..<42 {
            let a = CGFloat(t) * 0.42, rad = CGFloat(t) * 0.22
            let pt = CGPoint(x: 11 + cos(a) * rad, y: 11 + sin(a) * rad)
            if t == 0 { spiral.move(to: pt) } else { spiral.addLine(to: pt) }
        }
        let zig = P([(1, 14), (5, 6), (9, 14), (13, 6), (17, 14), (21, 6)], close: false)
        let circle = Path(ellipseIn: CGRect(x: 3, y: 3, width: 16, height: 16))
        var plus = Path()
        plus.move(to: CGPoint(x: 11, y: 2)); plus.addLine(to: CGPoint(x: 11, y: 20))
        plus.move(to: CGPoint(x: 2, y: 11)); plus.addLine(to: CGPoint(x: 20, y: 11))
        let tri = P([(3, 19), (11, 3), (19, 19)], close: true)
        var squig = Path()
        squig.move(to: CGPoint(x: 2, y: 11))
        squig.addCurve(to: CGPoint(x: 14, y: 11), control1: CGPoint(x: 6, y: 3), control2: CGPoint(x: 10, y: 19))
        squig.addCurve(to: CGPoint(x: 21, y: 11), control1: CGPoint(x: 18, y: 3), control2: CGPoint(x: 20, y: 7))
        return [star, spiral, zig, circle, plus, tri, squig]
    }()
    static let words = ["BOOP", "!!", "CLICK", "★", "YES", "?!", "POW"]
}

// MARK: - Backdrop

private struct ZBackdrop: View {
    var body: some View {
        ZStack {
            ZInk.page
            Canvas { ctx, size in
                // Photocopy halftone.
                var dots = Path()
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width { dots.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6)); x += 7 }
                    y += 7
                }
                ctx.fill(dots, with: .color(ZInk.halftone))
                // Cutting-mat grid: minor every 28pt, major every 5 cells.
                var minor = Path(), major = Path()
                let cell: CGFloat = 28
                for i in 0...Int(size.width / cell) + 1 {
                    let x = CGFloat(i) * cell
                    var p = i % 5 == 0 ? major : minor
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    if i % 5 == 0 { major = p } else { minor = p }
                }
                for i in 0...Int(size.height / cell) + 1 {
                    let y = CGFloat(i) * cell
                    var p = i % 5 == 0 ? major : minor
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    if i % 5 == 0 { major = p } else { minor = p }
                }
                ctx.stroke(minor, with: .color(ZInk.gridMinor), lineWidth: 1)
                ctx.stroke(major, with: .color(ZInk.gridMajor), lineWidth: 1.3)
            }
        }
    }
}

// MARK: - Sticker buttons

private struct ZLook {
    var ink: ZInkKey?   // nil: plain paper sticker
    var tilt: Double
    var corner: Int
    var tearSeed: UInt64
}

private let zBaseInk: [String: ZInkKey] = [
    "back": .blue, "home": .yellow, "type": .violet, "laser": .orange, "recenter": .teal,
    "ok": .pink, "rewind": .yellow, "playpause": .pink, "forward": .yellow,
]
private let zNotes: [String: String] = [
    "back": "nope.", "home": "base!", "type": "words", "laser": "pew", "recenter": "↺ middle",
    "ok": "(the big one)", "rewind": "rew", "playpause": "play/pause", "forward": "ffwd",
]

private func zLook(_ b: SkinButton, chaos: Bool, shuffle: Int) -> ZLook {
    let seed = zSeed(b.id)
    var g = ZRNG(seed)
    let isOK = b.role == .ok
    var look = ZLook(ink: zBaseInk[b.id] ?? ZInkKey(rawValue: Int(seed % 6)),
                     tilt: isOK ? -1.6 : Double(g.range(-2.4, 2.4)),
                     corner: Int(g.next() % 4), tearSeed: seed)
    if case .toggle(let on) = b.role, !on { look.ink = nil }
    if !b.enabled { look.ink = nil }
    if chaos {
        var c = ZRNG(seed &+ UInt64(shuffle) &* 7919)
        look.ink = ZInkKey(rawValue: Int(c.next() % 6))
        look.tilt = Double(c.range(isOK ? -4 : -8, isOK ? 4 : 8))
        look.corner = Int(c.next() % 4)
        look.tearSeed = c.next()
    }
    return look
}

private struct ZStickerFace: View {
    let b: SkinButton
    let pressed: Bool
    @ObservedObject private var zs = ZineState.shared
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var width: CGFloat = 200

    var body: some View {
        let look = zLook(b, chaos: zs.chaos, shuffle: zs.shuffle)
        let torn = ZTorn(seed: look.tearSeed, corner: look.corner)
        let fill = look.ink?.fill ?? ZInk.pad
        let ghost = look.ink?.ghost ?? ZInk.pink
        let text = look.ink?.text ?? ZInk.ink
        let ghostShift: CGSize = zs.misreg ? CGSize(width: 8, height: 6) : (calm ? CGSize(width: 2, height: 1.5) : CGSize(width: 3, height: 2))
        let wobble: Double = (look.tearSeed % 2 == 0 ? 2.6 : -2.6)
        let squash = pressed && !calm

        ZStack {
            torn.fill(ghost)
                .opacity(look.ink == nil ? 0.25 : 0.6)
                .offset(ghostShift)
            torn.fill(fill)
                .overlay(ZHalftone().clipShape(torn))
            if !b.enabled {
                torn.stroke(ZInk.inkSoft, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            content(text: text, ghost: ghost)
            ZPeel(corner: look.corner)
                .fill(LinearGradient(colors: [ZInk.peel, ZInk.peel2], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .padding(3)
        .compositingGroup()
        .shadow(color: ZInk.shadow, radius: 0, x: pressed ? 1 : 2, y: pressed ? 1 : 3)
        .rotationEffect(.degrees(calm ? 0 : look.tilt + (pressed ? wobble : 0)))
        .scaleEffect(x: squash ? 0.95 : 1, y: squash ? 0.88 : 1)
        .offset(calm && pressed ? CGSize(width: 1, height: 2) : .zero)
        .animation(calm ? nil : .spring(response: 0.24, dampingFraction: 0.38), value: pressed)
        .animation(calm ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: zs.shuffle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
            width = r.width
            if b.id == "ok" { ZFrames.shared.set(\.ok, r) }
        }
    }

    @ViewBuilder private func content(text: Color, ghost: Color) -> some View {
        // Marker notes only where they can't crowd the label (narrow stickers stack icon over label).
        let roomy = b.role == .ok || b.role == .media || width >= 108
        let note = !roomy ? "" : b.enabled ? (zNotes[b.id] ?? "") : "(zzz)"
        ZStack {
            switch b.role {
            case .ok:
                GeometryReader { geo in
                    let h = geo.size.height
                    let ringH = min(h * 0.8, 120), size = min(60, h * 0.5)
                    ZStack {
                        ZRing()
                            .stroke(ZInk.sticker.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: ringH * 1.55, height: ringH)
                        Text("OK")
                            .font(ZFont.display(size))
                            .foregroundStyle(text)
                            .shadow(color: ghost.opacity(0.7), radius: 0, x: 3, y: 2)
                    }
                    .frame(width: geo.size.width, height: h)
                    .offset(y: -2)
                }
            case .media:
                Image(systemName: b.symbol)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(text)
                    .shadow(color: ghost.opacity(0.6), radius: 0, x: 1.5, y: 1.2)
                    .offset(y: -4)
            case .normal, .toggle:
                let label = labelText
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        icon
                        Text(label).font(ZFont.display(14)).lineLimit(1).fixedSize()
                    }
                    VStack(spacing: 3) {
                        icon
                        Text(label).font(ZFont.display(12)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .offset(y: -3)
                }
                .padding(.horizontal, 6)
                .foregroundStyle(text)
                .shadow(color: ghost.opacity(0.65), radius: 0, x: 1.5, y: 1.2)
            }
            if case .toggle(let on) = b.role {
                Text(on ? "ON" : "OFF")
                    .font(ZFont.display(9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(Rectangle().stroke(text, lineWidth: 2))
                    .foregroundStyle(text)
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 8).padding(.top, 6)
            }
            if !note.isEmpty {
                Text(note)
                    .font(ZFont.hand(b.role == .ok ? 12 : 10.5))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(text.opacity(0.85))
                    .rotationEffect(.degrees(-5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, b.role == .ok ? 12 : 8).padding(.bottom, b.role == .ok ? 6 : 4)
            }
        }
    }

    private var icon: some View {
        Image(systemName: b.symbol).font(.system(size: 19, weight: .heavy))
    }

    /// "Laser on" → "LASER" (the stamp carries on/off).
    private var labelText: String {
        if case .toggle = b.role { return (b.label.split(separator: " ").first.map(String.init) ?? b.label).uppercased() }
        return b.label.uppercased()
    }
}

// MARK: - Gear

private struct ZGear: View {
    let pressed: Bool
    @ObservedObject private var zs = ZineState.shared
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        let blob = ZBlob(seed: 3, wobble: 0.05)
        ZStack {
            blob.fill(ZInk.pink).opacity(0.6).offset(zs.misreg ? CGSize(width: 7, height: 5) : CGSize(width: 3, height: 2))
            blob.fill(ZInk.pad).overlay(ZHalftone().clipShape(blob))
            Image(systemName: "gearshape")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(ZInk.ink)
        }
        .frame(width: 48, height: 48)
        .compositingGroup()
        .shadow(color: ZInk.shadow, radius: 0, x: pressed ? 1 : 2, y: pressed ? 1 : 3)
        .rotationEffect(.degrees(calm ? 0 : (pressed ? 200 : 8)))
        .scaleEffect(pressed && !calm ? 1.12 : 1)
        .animation(calm ? nil : (pressed ? .easeIn(duration: 0.5) : .spring(response: 0.45, dampingFraction: 0.5)), value: pressed)
        .padding(2)
    }
}

// MARK: - Status dot and subtitle

private struct ZDot: View {
    let connected: Bool
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        ZStack {
            ZBlob(seed: 11, wobble: 0.12)
                .stroke(ZInk.pink, lineWidth: 2)
                .frame(width: 38, height: 34)
                .rotationEffect(.degrees(20))
            Circle().fill(ZInk.ink).frame(width: 30, height: 30)
                .shadow(color: ZInk.shadow, radius: 0, x: 2, y: 2)
            Circle().fill(ZInk.page).frame(width: 26, height: 26)
            light
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .onTapGesture { ZineState.shared.tapDot() }
        .accessibilityLabel(connected ? "Connected" : "Not connected")
    }

    @ViewBuilder private var light: some View {
        let dot = Circle().fill(connected ? ZInk.green : ZInk.yellow).frame(width: 20, height: 20)
        if connected || calm {
            dot
        } else {
            dot.phaseAnimator([1.0, 0.7]) { v, s in v.scaleEffect(s) } animation: { _ in .easeInOut(duration: 0.6) }
        }
    }
}

private struct ZSubtitle: View {
    let status: String
    @State private var level = -1
    @State private var wiggle = 0.0
    @State private var reset: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var calm

    private var lines: [String] {
        if status.hasPrefix("Connected") {
            return ["Connected. Very connected.", "Connected-er than ever", "the TV can hear you", "the TV is ignoring you",
                    "I have become the remote", "REMOTE? I AM THE CONTROLLER", "everything is a pointer",
                    "the pointer is pointing at ME", "ok ok. breathing. connected."]
        }
        return ["still looking. squinting.", "TV? TV?? hello??", "checking under the couch", "the TV is hiding from you",
                "maybe it's behind the plant", "I HAVE BECOME THE SEARCH", "everything is a TV if you squint",
                "the TV is looking for ME", "ok ok. breathing. searching."]
    }

    private var lineColor: Color {
        switch level / 2 + 1 {
        case 1: return ZInk.ink
        case 2: return ZInk.blueText
        case 3: return ZInk.violetText
        case 4: return ZInk.orangeText
        default: return ZInk.pinkText
        }
    }

    var body: some View {
        Group {
            if level < 0 {
                Text(status).font(.custom(ZFont.mono, size: 12, relativeTo: .caption)).foregroundStyle(ZInk.inkSoft)
            } else {
                Text(lines[level]).font(ZFont.hand(14)).foregroundStyle(lineColor)
            }
        }
        .lineLimit(1)
        .frame(minHeight: 20, alignment: .leading)
        .rotationEffect(.degrees(wiggle), anchor: .leading)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .global) { loc in advance(loc) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap for nonsense")
    }

    private func advance(_ loc: CGPoint) {
        Haptics.tick()
        level += 1
        if level >= lines.count { level = -1; reset?.cancel(); return }
        if !calm {
            let angle = (level % 2 == 0 ? -3.0 : 3.0) * (1 + Double(level) * 0.3)
            withAnimation(.spring(response: 0.15, dampingFraction: 0.5)) { wiggle = angle }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { wiggle = 0 }
            }
        }
        if level == lines.count - 1 {
            ZineState.shared.burstAt.send(loc)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        reset?.cancel()
        let work = DispatchWorkItem { level = -1 }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

// MARK: - Speed control

private struct ZSpeed: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var lastTick = 0
    @Environment(\.accessibilityReduceMotion) private var calm

    private var frac: CGFloat {
        CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        HStack(spacing: 6) {
            end("tortoise.fill", "slow-ish")
            GeometryReader { geo in track(width: geo.size.width) }
                .frame(height: 44)
            end("hare.fill", "zoomy")
        }
        .frame(minHeight: 54)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pointer speed")
        .accessibilityValue(String(format: "%.1f times", value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step)))
        }
    }

    private func end(_ symbol: String, _ note: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 21, weight: .bold)).foregroundStyle(ZInk.ink)
            Text(note).font(ZFont.hand(10)).foregroundStyle(ZInk.inkSoft).fixedSize().rotationEffect(.degrees(-4))
        }
        .frame(width: 46, height: 44)
    }

    private func track(width w: CGFloat) -> some View {
        let inset: CGFloat = 18
        let x = inset + frac * max(1, w - inset * 2)
        return ZStack(alignment: .topLeading) {
            ZScribble(seed: 42, passes: 2)
                .stroke(ZInk.ink.opacity(0.55), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: w - inset * 2, height: 24)
                .offset(x: inset, y: 10)
            ZScribble(seed: 42, passes: 1)
                .trim(from: 0, to: frac)
                .stroke(ZInk.pink, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: w - inset * 2, height: 24)
                .offset(x: inset, y: 10)
            ZStack {
                ZStar().fill(ZInk.yellow)
                ZStar().stroke(ZInk.sticker, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                Circle().fill(ZInk.pink).frame(width: 6, height: 6)
            }
            .frame(width: 34, height: 34)
            .rotationEffect(.degrees(calm ? 0 : Double(frac) * 216))
            .shadow(color: ZInk.shadow, radius: 0, x: 2, y: 2)
            .position(x: x, y: 22)
            Text(String(format: "x%.1f", value))
                .font(ZFont.hand(11))
                .foregroundStyle(ZInk.ink)
                .fixedSize()
                .rotationEffect(.degrees(-6))
                .position(x: x, y: -4)
        }
        .frame(width: w, height: 44)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let f = min(1, max(0, (g.location.x - inset) / max(1, w - inset * 2)))
            value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
            let tick = Int((value * 10).rounded())
            if tick != lastTick { lastTick = tick; Haptics.tick() }
        })
    }
}

// MARK: - Strips

private struct ZStripView: View {
    let vertical: Bool
    let s: StripState
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        let torn = ZTorn(seed: vertical ? 101 : 202, teeth: 10, amp: 3)
        let off = s.travel.truncatingRemainder(dividingBy: 16)
        ZStack {
            torn.fill(vertical ? ZInk.yellow : ZInk.pink)
            Canvas { ctx, size in
                var p = Path()
                if vertical {
                    var y = off - 16
                    while y < size.height + 16 {
                        p.move(to: CGPoint(x: 2, y: y)); p.addLine(to: CGPoint(x: size.width - 2, y: y + 5)); y += 16
                    }
                } else {
                    var x = off - 16
                    while x < size.width + 16 {
                        p.move(to: CGPoint(x: x, y: 2)); p.addLine(to: CGPoint(x: x + 5, y: size.height - 2)); x += 16
                    }
                }
                ctx.stroke(p, with: .color(ZInk.sticker.opacity(0.28)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
            .clipShape(torn)
            chevrons
            Text(vertical ? "scroll" : "slide")
                .font(ZFont.hand(13))
                .foregroundStyle(ZInk.ink)
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(ZInk.pad, in: RoundedRectangle(cornerRadius: 3))
                .rotationEffect(.degrees(vertical ? 90 : 0))
        }
        .padding(2)
        .compositingGroup()
        .shadow(color: ZInk.shadow, radius: 0, x: 2, y: 3)
        .saturation(s.touching ? 1.3 : 1)
        .brightness(s.touching ? 0.06 : 0)
        .rotationEffect(.degrees(calm ? 0 : (vertical ? 0.8 : -0.5)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
            ZFrames.shared.set(vertical ? \ZFrames.vstrip : \ZFrames.hstrip, r)
        }
        .onChange(of: s.touching) { _, on in
            if on { ZineState.shared.lastStrip = (vertical, Date()) }
        }
    }

    private var chevrons: some View {
        let font = Font.system(size: 15, weight: .black)
        return Group {
            if vertical {
                VStack {
                    Image(systemName: "chevron.up"); Spacer(); Image(systemName: "chevron.down")
                }
                .padding(.vertical, 9)
            } else {
                HStack {
                    Image(systemName: "chevron.left"); Spacer(); Image(systemName: "chevron.right")
                }
                .padding(.horizontal, 11)
            }
        }
        .font(font)
        .foregroundStyle(ZInk.sticker)
    }
}

// MARK: - Touchpad

private final class ZTrail {
    struct Pt { var p: CGPoint; var t: TimeInterval; var jx: CGFloat; var jy: CGFloat; var brk: Bool }
    static let life: TimeInterval = 0.65
    var pts: [Pt] = []
    var pendingBreak = true

    func add(_ p: CGPoint, now: TimeInterval) {
        pts.append(Pt(p: p, t: now, jx: .random(in: -1.4...1.4), jy: .random(in: -1.4...1.4), brk: pendingBreak))
        pendingBreak = false
        if let i = pts.firstIndex(where: { now - $0.t <= Self.life }) { pts.removeFirst(i) } else { pts.removeAll() }
        if pts.count > 160 { pts.removeFirst(pts.count - 160) }
    }
}

private enum ZQuips {
    static let drag = ["pointing at stuff…", "wheeeee", "aiming. carefully.", "zoom zoom", "pointer go brrr"]
    static let click = ["clicked it. probably.", "boop.", "*click*", "that's a click", "done. i think."]
    static let long = ["holding… holding…", "long press, very serious", "commitment!"]
    static let back = ["nope, going back", "two fingers = undo life", "back we go"]
    static let strip = ["scrolling, allegedly", "step step step", "down the list we go"]
    static let idle = ["ready when u are", "waiting. patiently. ish.", "point at the TV, not your friend",
                       "this pad is load-bearing", "hi :)"]
    static let home = ["home sweet home", "back to base"]
    static let type = ["typing mode ✎", "spell it out"]
    static let rec = ["back to the middle", "re-centred. zen."]
    static let laser = ["pew pew?", "laser toggled. allegedly."]
    static let chaos = ["AAAAAAA", "what did you DO", "sticker storm!!"]
    static let hello = ["the TV said hi", "connected!! hi TV"]
}

private struct ZPadView: View {
    let s: PadState
    @EnvironmentObject private var fx: SkinFX
    @ObservedObject private var zs = ZineState.shared
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var trail = ZTrail()
    @State private var live = false
    @State private var stopWork: DispatchWorkItem?
    @State private var quip = "ready when u are"
    @State private var slap: CGFloat = 1
    @State private var lastDragQuip = Date.distantPast
    @State private var idleWork: DispatchWorkItem?
    @State private var holdPoint: CGPoint = .zero

    var body: some View {
        let torn = ZTorn(seed: 77, teeth: 14, amp: 3.5)
        ZStack {
            paper(torn)
                .compositingGroup()
                .shadow(color: ZInk.shadow, radius: 0, x: 3, y: 4)
                .rotationEffect(.degrees(calm ? 0 : -0.6))
                .scaleEffect(s.holdProgress >= 1 && s.touching ? 0.985 : 1)
            washi
            trailLayer
            holdRing
            quipTag
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
            if zs.chaos { chaosBanner }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ZFrames.shared.set(\.pad, $0) }
        .onChange(of: s.touching) { _, on in if on { trail.pendingBreak = true } }
        .onChange(of: s.location) { _, p in
            guard let p else { return }
            zs.lastPadPoint = p
            holdPoint = p
            trail.add(p, now: Date().timeIntervalSinceReferenceDate)
            if !live { live = true }
            stopWork?.cancel()
            let work = DispatchWorkItem { live = false }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ZTrail.life + 0.15, execute: work)
        }
        .onReceive(fx.$last) { e in react(e) }
        .onChange(of: zs.chaos) { _, on in if on { setQuip(ZQuips.chaos) } }
        .onAppear { zs.reduceMotion = calm; scheduleIdle() }
        .onChange(of: calm) { _, c in zs.reduceMotion = c }
    }

    private func paper(_ torn: ZTorn) -> some View {
        ZStack {
            torn.fill(ZInk.pad)
            Canvas { ctx, size in
                var grid = Path()
                var x: CGFloat = 0
                while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += 22 }
                var y: CGFloat = 0
                while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += 22 }
                ctx.stroke(grid, with: .color(ZInk.padGrid), lineWidth: 1)
                // Halftone fade growing into the bottom-right corner.
                var dots = Path()
                let step: CGFloat = 8
                var yy: CGFloat = 0
                while yy < size.height {
                    var xx: CGFloat = 0
                    while xx < size.width {
                        let u = (xx / size.width + yy / size.height) / 2
                        let r = max(0, (u - 0.45) / 0.55) * 2.6
                        if r > 0.3 { dots.addEllipse(in: CGRect(x: xx - r, y: yy - r, width: r * 2, height: r * 2)) }
                        xx += step
                    }
                    yy += step
                }
                ctx.fill(dots, with: .color(ZInk.pink.opacity(0.24)))
            }
            ZStack {
                bigWords.foregroundStyle(ZInk.pink.opacity(0.16)).offset(x: 6, y: 4)
                bigWords.foregroundStyle(ZInk.ink.opacity(0.09))
            }
            .rotationEffect(.degrees(-7))
            .offset(y: -10)
            legend
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .clipShape(torn)
    }

    private var bigWords: some View {
        VStack(spacing: -22) { Text("TOUCH"); Text("PAD") }.font(ZFont.display(54))
    }

    private var legend: some View {
        let k = ZInk.pinkText
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(Text("drag").foregroundStyle(k)) → move · \(Text("tap").foregroundStyle(k)) → click")
            Text("\(Text("hold").foregroundStyle(k)) → long press · \(Text("2 fingers").foregroundStyle(k)) → back")
        }
        .font(ZFont.hand(12.5))
        .foregroundStyle(ZInk.inkSoft)
        .rotationEffect(.degrees(calm ? 0 : -1.2), anchor: .leading)
    }

    private var washi: some View {
        ZStack {
            ZWashi().fill(ZInk.yellow.opacity(0.78)).frame(width: 74, height: 22)
                .rotationEffect(.degrees(-38))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -16, y: 4)
            ZWashi().fill(ZInk.teal.opacity(0.7)).frame(width: 70, height: 22)
                .rotationEffect(.degrees(32))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 16, y: 8)
            ZWashi().fill(ZInk.pink.opacity(0.6)).frame(width: 56, height: 20)
                .rotationEffect(.degrees(-6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: -18, y: 6)
        }
        .allowsHitTesting(false)
    }

    private var trailLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !live)) { tl in
            Canvas { ctx, _ in
                let now = tl.date.timeIntervalSinceReferenceDate
                let pts = trail.pts
                guard pts.count > 1 else { return }
                let passes: [(CGFloat, CGFloat, Color, CGFloat)] = calm
                    ? [(0, 0, ZInk.pink, 3)]
                    : [(1.6, 1.1, ZInk.pink, 3.2), (-1.2, -0.8, ZInk.trailBlue, 2.2)]
                let jit: CGFloat = calm ? 0 : 1
                for i in 1..<pts.count where !pts[i].brk {
                    let a = pts[i - 1], b = pts[i]
                    let alpha = max(0, 1 - (now - b.t) / ZTrail.life)
                    guard alpha > 0 else { continue }
                    for (ox, oy, col, lw) in passes {
                        var p = Path()
                        p.move(to: CGPoint(x: a.p.x + ox + a.jx * jit, y: a.p.y + oy + a.jy * jit))
                        p.addLine(to: CGPoint(x: b.p.x + ox + b.jx * jit, y: b.p.y + oy + b.jy * jit))
                        ctx.stroke(p, with: .color(col.opacity(alpha * 0.9)),
                                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Marker circle that draws itself while a still finger is held.
    private var holdRing: some View {
        Circle()
            .trim(from: 0, to: s.holdProgress)
            .stroke(ZInk.pink, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 58, height: 58)
            .position(holdPoint)
            .opacity(s.touching && s.holdProgress > 0 ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var quipTag: some View {
        Text(quip)
            .font(ZFont.hand(14))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 5)
            .background(ZInk.sticker)
            .overlay(Rectangle().stroke(ZInk.ink.opacity(0.25), lineWidth: 1))
            .compositingGroup()
            .shadow(color: ZInk.pink, radius: 0, x: 3, y: 3)
            .rotationEffect(.degrees(calm ? 0 : -2.5))
            .scaleEffect(slap)
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var chaosBanner: some View {
        Text("CHAOS MODE!!")
            .font(ZFont.display(30))
            .foregroundStyle(ZInk.sticker)
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(ZInk.yellow)
            .compositingGroup()
            .shadow(color: ZInk.pink, radius: 0, x: 5, y: 5)
            .shadow(color: ZInk.blue, radius: 0, x: -3, y: -3)
            .rotationEffect(.degrees(calm ? 0 : -9))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .transition(calm ? .opacity : .scale(scale: 2).combined(with: .opacity))
            .allowsHitTesting(false)
    }

    private func react(_ e: SkinFX.Event) {
        switch e {
        case .move(let dx, _):
            zs.noteMove(dx: dx)
            if Date().timeIntervalSince(lastDragQuip) > 1.6 { lastDragQuip = Date(); setQuip(ZQuips.drag) }
        case .padDown: zs.lastPadDown = Date()
        case .click: setQuip(ZQuips.click)
        case .longPress: setQuip(ZQuips.long)
        case .step: setQuip(ZQuips.strip)
        case .connected(let on): if on { setQuip(ZQuips.hello) }
        case .button(let id):
            switch id {
            case "back": setQuip(ZQuips.back)
            case "home": setQuip(ZQuips.home)
            case "type": setQuip(ZQuips.type)
            case "recenter": setQuip(ZQuips.rec)
            case "laser": setQuip(ZQuips.laser)
            default: break
            }
        case .padUp: break
        }
    }

    private func setQuip(_ options: [String]) {
        guard let q = options.filter({ $0 != quip }).randomElement() else { return }
        quip = q
        if !calm {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { slap = 1.3 }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) { slap = 1 }
            }
        }
        scheduleIdle()
    }

    private func scheduleIdle() {
        idleWork?.cancel()
        let work = DispatchWorkItem { setQuip(ZQuips.idle) }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5, execute: work)
    }
}

// MARK: - Effects (bursts, confetti, critter)

private struct ZParticle {
    var kind: Int
    var color: Color
    var angle: CGFloat
    var dist: CGFloat
    var scale: CGFloat
    var rot: CGFloat
    var dur: TimeInterval
}

private struct ZBurst: Identifiable {
    let id = UUID()
    var center: CGPoint
    var start: Date
    var calm: Bool
    var word: String?
    var wordBG: Color
    var particles: [ZParticle]
}

/// Reads `fx` once and hands it down unobserved, so pad moves don't redraw the effects layer.
private struct ZEffectsHost: View {
    @EnvironmentObject private var fx: SkinFX
    var body: some View { ZEffects(fx: fx) }
}

private struct ZEffects: View {
    let fx: SkinFX
    @ObservedObject private var frames = ZFrames.shared
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var bursts: [ZBurst] = []
    @State private var bounds: CGRect = .zero
    @State private var critter = false
    @State private var critterSays = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: nil, paused: bursts.isEmpty)) { tl in
                Canvas { ctx, _ in draw(&ctx, now: tl.date) }
            }
            corner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds = $0 }
        .onReceive(fx.$last) { e in handle(e) }
        .onReceive(fx.$clicks) { n in
            if n >= 100 && !critter {
                withAnimation(calm ? nil : .spring(response: 0.5, dampingFraction: 0.55)) { critter = true }
                critterSays = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { withAnimation { critterSays = false } }
            }
        }
        .onReceive(ZineState.shared.confetti) { n in
            guard !calm, bounds.width > 40, bounds.height > 120 else { return }
            let p = CGPoint(x: .random(in: 20...(bounds.width - 20)), y: .random(in: 60...(bounds.height - 60)))
            addBurst(at: p, count: 6, word: n % 3 == 0)
        }
        .onReceive(ZineState.shared.burstAt) { g in
            addBurst(at: CGPoint(x: g.x - bounds.minX, y: g.y - bounds.minY), count: 12, word: true)
        }
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }

    private func handle(_ e: SkinFX.Event) {
        let zs = ZineState.shared
        switch e {
        case .button(let id): zs.lastButton = (id, Date())
        case .click:
            let now = Date()
            var p: CGPoint?
            if let b = zs.lastButton, b.id == "ok", now.timeIntervalSince(b.at) < 0.3, frames.ok != .zero {
                let r = local(frames.ok); p = CGPoint(x: r.midX, y: r.midY - 10)
            } else if let st = zs.lastStrip, st.at > zs.lastPadDown, now.timeIntervalSince(st.at) < 2 {
                let r = local(st.vertical ? frames.vstrip : frames.hstrip); p = CGPoint(x: r.midX, y: r.midY)
            } else if frames.pad != .zero {
                let r = local(frames.pad)
                let q = zs.lastPadPoint ?? CGPoint(x: r.width / 2, y: r.height / 2)
                p = CGPoint(x: r.minX + q.x, y: r.minY + q.y)
            }
            if let p { addBurst(at: p, count: 9, word: true) }
        default: break
        }
    }

    private func addBurst(at p: CGPoint, count: Int, word: Bool) {
        let parts: [ZParticle] = (0..<count).map { _ in
            ZParticle(kind: Int.random(in: 0..<ZDoodle.paths.count), color: ZInk.all.randomElement()!,
                      angle: .random(in: 0...(2 * .pi)), dist: .random(in: 26...70), scale: .random(in: 0.6...1.3),
                      rot: .random(in: -200...200), dur: .random(in: 0.6...0.9))
        }
        let b = ZBurst(center: p, start: Date(), calm: calm, word: word && !calm ? ZDoodle.words.randomElement() : nil,
                       wordBG: [ZInk.yellow, ZInk.pink, Color.white].randomElement()!, particles: parts)
        bursts.append(b)
        if bursts.count > 14 { bursts.removeFirst(bursts.count - 14) }
        let id = b.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { bursts.removeAll { $0.id == id } }
    }

    private func draw(_ ctx: inout GraphicsContext, now: Date) {
        let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        for b in bursts {
            let t = now.timeIntervalSince(b.start)
            if b.calm {
                // Calm: a single ring that fades in place.
                let a = max(0, 1 - t / 0.5)
                var c = ctx
                c.opacity = a
                c.translateBy(x: b.center.x - 11, y: b.center.y - 11)
                c.stroke(ZDoodle.paths[3], with: .color(ZInk.pink), style: style)
                continue
            }
            for p in b.particles {
                let u = min(1, max(0, t / p.dur))
                guard u < 1 else { continue }
                var dx: CGFloat, dy: CGFloat, sc: CGFloat, rot: CGFloat, op: Double
                if u < 0.55 {
                    let k = 1 - pow(1 - u / 0.55, 3)
                    dx = cos(p.angle) * p.dist * k; dy = sin(p.angle) * p.dist * k
                    sc = 0.2 + (p.scale - 0.2) * k; rot = p.rot * k; op = 1
                } else {
                    let k = (u - 0.55) / 0.45
                    dx = cos(p.angle) * p.dist * (1 + 0.15 * k)
                    dy = sin(p.angle) * p.dist + 18 * k
                    sc = p.scale * (1 - 0.2 * k); rot = p.rot * (1 + 0.3 * k); op = 1 - k
                }
                var c = ctx
                c.opacity = op
                c.translateBy(x: b.center.x + dx, y: b.center.y + dy)
                c.rotate(by: .degrees(rot))
                c.scaleBy(x: sc, y: sc)
                c.translateBy(x: -11, y: -11)
                c.stroke(ZDoodle.paths[p.kind], with: .color(p.color), style: style)
            }
            if let w = b.word {
                let u = min(1, t / 0.75)
                guard u < 1 else { continue }
                let rise: CGFloat = u < 0.55 ? -26 * (1 - pow(1 - u / 0.55, 3)) : -26 + 18 * ((u - 0.55) / 0.45)
                var c = ctx
                c.opacity = u < 0.55 ? 1 : 1 - (u - 0.55) / 0.45
                let text = c.resolve(Text(w).font(ZFont.display(16)).foregroundColor(ZInk.sticker))
                let sz = text.measure(in: CGSize(width: 200, height: 40))
                let rect = CGRect(x: b.center.x - sz.width / 2 - 5, y: b.center.y + rise - sz.height / 2,
                                  width: sz.width + 10, height: sz.height)
                c.translateBy(x: rect.midX, y: rect.midY)
                c.rotate(by: .degrees(-6))
                c.translateBy(x: -rect.midX, y: -rect.midY)
                c.fill(Path(rect), with: .color(b.wordBG))
                c.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    /// The empty corner between the strips: a doodled arrow, or Clicky after 100 clicks.
    @ViewBuilder private var corner: some View {
        if frames.vstrip != .zero && frames.hstrip != .zero {
            let v = local(frames.vstrip), h = local(frames.hstrip)
            let r = CGRect(x: v.minX, y: h.minY, width: v.width, height: h.height)
            ZStack {
                if critter {
                    ZCritter()
                        .frame(width: 46, height: 46)
                        .transition(calm ? .opacity : .offset(y: 30).combined(with: .scale(scale: 0.3)))
                    if critterSays {
                        Text("hi. i'm clicky.")
                            .font(ZFont.hand(13))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(ZInk.sticker)
                            .compositingGroup()
                            .shadow(color: ZInk.pink, radius: 0, x: 2, y: 2)
                            .rotationEffect(.degrees(calm ? 0 : -4))
                            .offset(x: -74, y: -34)
                            .transition(.opacity)
                    }
                } else {
                    ZCornerArrow()
                        .stroke(ZInk.inkSoft, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 30, height: 30)
                }
            }
            .position(x: r.midX, y: r.midY)
        }
    }
}

private struct ZCornerArrow: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 30 * r.width, y: r.minY + y / 30 * r.height) }
        var p = Path()
        p.move(to: pt(26, 26))
        p.addCurve(to: pt(6, 6), control1: pt(14, 24), control2: pt(8, 18))
        p.move(to: pt(6, 6)); p.addLine(to: pt(4, 13))
        p.move(to: pt(6, 6)); p.addLine(to: pt(12, 9))
        return p
    }
}

private struct ZCritter: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 46
            ctx.scaleBy(x: s, y: s)
            var blob = Path()
            blob.move(to: CGPoint(x: 8, y: 40))
            blob.addCurve(to: CGPoint(x: 23, y: 6), control1: CGPoint(x: 2, y: 22), control2: CGPoint(x: 10, y: 6))
            blob.addCurve(to: CGPoint(x: 38, y: 40), control1: CGPoint(x: 37, y: 6), control2: CGPoint(x: 44, y: 22))
            blob.closeSubpath()
            ctx.fill(blob, with: .color(ZInk.pink))
            ctx.stroke(blob, with: .color(ZInk.sticker), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            for x in [17.0, 30.0] {
                let eye = Path(ellipseIn: CGRect(x: x - 5, y: 15, width: 10, height: 10))
                ctx.fill(eye, with: .color(.white))
                ctx.stroke(eye, with: .color(ZInk.sticker), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: 19, width: 4.5, height: 4.5)), with: .color(ZInk.sticker))
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 18, y: 31))
            smile.addQuadCurve(to: CGPoint(x: 29, y: 31), control: CGPoint(x: 23.5, y: 36))
            ctx.stroke(smile, with: .color(ZInk.sticker), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}
