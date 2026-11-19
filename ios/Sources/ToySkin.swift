import SwiftUI
import UIKit

// MARK: - Chunky Toy Remote
//
// A molded-plastic gadget: putty (light) or smoke (dark) shell, rubber keys in recessed wells,
// a tangerine OK key, a click knob for speed, ribbed thumbwheels, a rubber touchpad and an LCD
// that echoes what you just did.
//
// Easter eggs:
//  1. Barrel roll: swipe ▲▲▼▼◀▶◀▶ on the thumbwheels (or two-finger scroll) → the whole remote
//     spins two full turns and lands.
//     Each swipe counts once however many steps it moves, so a long swipe doesn't break the code.
//  2. Tap the speaker grille. It honks.

struct ToySkin: RemoteSkin {
    var colorScheme: ColorScheme? { nil }
    var tint: Color { toyHex(0xFF5B1F) }
    var ink: Color { toyDynamic(0x253019, 0x86FF9C) }          // LCD ink: the TV name sits on the LCD
    var inkSecondary: Color { toyDynamic(0x6E6450, 0x9A9BA6) }
    var titleFont: Font { .custom("VT323-Regular", size: 25) }
    var captionFont: Font { .custom("VT323-Regular", size: 17) }

    func backdrop() -> AnyView { AnyView(ToyBackdrop()) }
    func button(_ b: SkinButton, pressed: Bool) -> AnyView { AnyView(ToyKey(b: b, pressed: pressed)) }
    func pad(_ s: PadState) -> AnyView { AnyView(ToyPad(s: s)) }
    func strip(vertical: Bool, _ s: StripState) -> AnyView { AnyView(ToyStrip(vertical: vertical, s: s)) }
    func speedControl(value: Binding<Double>, range: ClosedRange<Double>) -> AnyView {
        AnyView(ToySpeed(value: value, range: range))
    }
    func statusDot(connected: Bool) -> AnyView { AnyView(ToyLED(connected: connected)) }
    func subtitle(status: String) -> AnyView { AnyView(ToySubtitle(status: status)) }
    func gear(pressed: Bool) -> AnyView { AnyView(ToyGear(pressed: pressed)) }
    func headerPanel() -> AnyView { AnyView(ToyLCDPanel()) }
}

// MARK: - Colors and fonts

private func toyHex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
          blue: Double(v & 0xFF) / 255, opacity: a)
}

private func toyUIHex(_ v: UInt32) -> UIColor {
    UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

private func toyDynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? toyUIHex(dark) : toyUIHex(light) })
}

private enum ToyFont {
    private static var cache: [Int: UIFont] = [:]
    /// Rubik is a variable font whose default instance is Light, so set the weight axis directly.
    static func rubik(_ size: CGFloat, _ weight: CGFloat = 800) -> Font {
        let key = Int(size * 10) * 10_000 + Int(weight)
        if let f = cache[key] { return Font(f as CTFont) }
        let font: UIFont
        if UIFont(name: "Rubik-Light", size: size) != nil {
            let wght = 0x7767_6874   // 'wght'
            let d = UIFontDescriptor(fontAttributes: [
                .name: "Rubik-Light",
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
            ])
            font = UIFont(descriptor: d, size: size)
        } else {
            let base = UIFont.systemFont(ofSize: size, weight: weight >= 750 ? .heavy : .bold)
            font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        cache[key] = font
        return Font(font as CTFont)
    }
    static func lcd(_ size: CGFloat) -> Font { .custom("VT323-Regular", size: size) }
}

private struct ToyPalette {
    var shell, shellHi, shellLo, label, well: Color
    var rubber, rubberHi, rubberLo, rubberInk: Color
    var accent, accentHi, accentLo, accentInk: Color
    var lcd, lcdInk: Color
    var lcdGlow: Bool
    var pad, padDot, padLogo, padHint: Color
    var pcb: Bool
    var darkShell: Bool

    static let light = ToyPalette(
        shell: toyHex(0xE8E2D5), shellHi: toyHex(0xFFFDF7), shellLo: toyHex(0xB7AD99), label: toyHex(0x6E6450), well: toyHex(0x8F8571),
        rubber: toyHex(0x3A393E), rubberHi: toyHex(0x58575E), rubberLo: toyHex(0x1C1B1F), rubberInk: toyHex(0xEFEAE0),
        accent: toyHex(0xFF5B1F), accentHi: toyHex(0xFF9466), accentLo: toyHex(0xB8380A), accentInk: toyHex(0xFFF3EA),
        lcd: toyHex(0xB8C59A), lcdInk: toyHex(0x253019), lcdGlow: false,
        pad: toyHex(0xDCD5C6), padDot: .black.opacity(0.09), padLogo: toyHex(0x7E745F), padHint: toyHex(0x5E5749),
        pcb: false, darkShell: false)

    static let dark = ToyPalette(
        shell: toyHex(0x2C2D33), shellHi: toyHex(0x4D4E57), shellLo: toyHex(0x121216), label: toyHex(0x9A9BA6), well: toyHex(0x0D0D10),
        rubber: toyHex(0x24252A), rubberHi: toyHex(0x3A3B42), rubberLo: toyHex(0x0A0A0C), rubberInk: toyHex(0xDCD8CF),
        accent: toyHex(0xFF5B1F), accentHi: toyHex(0xFF9466), accentLo: toyHex(0xB8380A), accentInk: toyHex(0xFFF3EA),
        lcd: toyHex(0x122016), lcdInk: toyHex(0x86FF9C), lcdGlow: true,
        pad: toyHex(0x23242A), padDot: .white.opacity(0.05), padLogo: toyHex(0x8A8B96), padHint: toyHex(0xB3AFA6),
        pcb: true, darkShell: true)

    static func make(_ scheme: ColorScheme) -> ToyPalette { scheme == .dark ? dark : light }
}

/// Debossed text on the shell: a highlight below on light plastic, a shadow above on dark.
private extension View {
    func toyEmboss(_ p: ToyPalette) -> some View {
        shadow(color: p.darkShell ? .black.opacity(0.55) : p.shellHi.opacity(0.9), radius: 0, x: 0, y: p.darkShell ? -1 : 1)
    }
}

// MARK: - Shared state (eggs, LCD echo)

private final class ToyStore: ObservableObject {
    static let shared = ToyStore()

    /// Temporary LCD text; nil shows the status.
    @Published var message: String?
    @Published var flash = 0

    private var messageToken = 0
    private var arrows = ""
    /// Direction of the swipe in progress: repeats within one swipe count once toward the code.
    private var swipeDir: Character?
    private var okAt = Date.distantPast

    func say(_ text: String, for seconds: Double = 1.3) {
        message = text
        flash &+= 1
        messageToken &+= 1
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.message = nil
        }
    }

    /// Every SkinFX event passes through here (subscribed by the LCD subtitle).
    func handle(_ e: SkinFX.Event) {
        switch e {
        case .padDown, .move: return
        case .padUp, .stripUp: swipeDir = nil
        case .click:
            // OK emits button(ok) then click; keep "OK" on the LCD.
            if Date().timeIntervalSince(okAt) < 0.15 { return }
            say("CLICK")
        case .longPress: say("LONG PRESS")
        case .step(let dx, let dy):
            let c: Character = dy < 0 ? "U" : dy > 0 ? "D" : dx < 0 ? "L" : "R"
            say(["U": "▲ UP", "D": "▼ DOWN", "L": "◄ LEFT", "R": "► RIGHT"][c] ?? "", for: 0.8)
            guard c != swipeDir else { return }
            swipeDir = c
            arrows = String((arrows + String(c)).suffix(8))
            if arrows == "UUDDLRLR" { arrows = ""; barrelRoll() }
        case .button(let id):
            switch id {
            case "back": say("◄ BACK")
            case "home": say("⌂ HOME")
            case "type": say("TYPE › KEYBOARD")
            case "recenter": say("⊕ RECENTERED")
            case "ok": okAt = Date(); say("● OK")
            case "rewind": say("◄◄ REWIND")
            case "forward": say("►► FORWARD")
            case "playpause": say("► PLAY / PAUSE")
            case "gear": say("☼ SETTINGS")
            default: break   // laser: its key face reports the new state
            }
        case .connected(let on): say(on ? "LINKED √" : "SIGNAL LOST", for: 1.8)
        }
    }

    func barrelRoll() {
        ScreenFX.shared.barrelRoll()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say("DO A BARREL ROLL!", for: 1.6)
        for t in [0.35, 0.65, 0.95, 1.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { Haptics.tap(.rigid) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            Haptics.tap(.heavy)
            self?.say("STUCK THE LANDING", for: 1.6)
        }
    }
}

/// Views that draw with the palette: observe the shared store and the appearance directly.
private protocol ToyLooking: View {
    var store: ToyStore { get }
    var scheme: ColorScheme { get }
}
private extension ToyLooking {
    var p: ToyPalette { ToyPalette.make(scheme) }
}

// MARK: - Shared pieces

/// A recessed socket molded into the shell.
private struct ToyWell<S: Shape>: View {
    let shape: S
    let p: ToyPalette
    var depth: CGFloat = 3

    var body: some View {
        shape
            .fill(p.well.shadow(.inner(color: .black.opacity(0.5), radius: depth, x: 0, y: depth)))
            .background(shape.fill(p.shellHi.opacity(p.darkShell ? 0.7 : 1)).offset(y: 1.5))
    }
}

private struct DotGrid: View, Equatable {
    let color: Color
    let spacing: CGFloat
    let radius: CGFloat
    var highlight: Color? = nil

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / spacing), rows = Int(size.height / spacing)
            let x0 = (size.width - CGFloat(cols - 1) * spacing) / 2
            let y0 = (size.height - CGFloat(rows - 1) * spacing) / 2
            for r in 0..<max(rows, 0) {
                for c in 0..<max(cols, 0) {
                    let pt = CGPoint(x: x0 + CGFloat(c) * spacing, y: y0 + CGFloat(r) * spacing)
                    if let highlight {
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius + 0.9, width: radius * 2, height: radius * 2)),
                                 with: .color(highlight))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color))
                }
            }
        }
    }
}

/// Knurled rim: alternating wedges.
private struct Knurl: View, Equatable {
    let a: Color
    let b: Color
    let count: Int
    let fraction: Double

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(a))
            let step = 360 / Double(count)
            for i in 0..<count {
                let start = Double(i) * step + step * (1 - fraction)
                var path = Path()
                path.move(to: c)
                path.addArc(center: c, radius: r, startAngle: .degrees(start), endAngle: .degrees(start + step * fraction), clockwise: false)
                path.closeSubpath()
                ctx.fill(path, with: .color(b))
            }
        }
    }
}

// MARK: - Backdrop

private struct ToyBackdrop: ToyLooking {
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let p = p
        GeometryReader { geo in
            ZStack {
                p.shell
                RadialGradient(colors: [p.shellHi.opacity(p.darkShell ? 0.5 : 0.95), p.shellHi.opacity(0)],
                               center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.5)
                LinearGradient(stops: [.init(color: .clear, location: 0.7), .init(color: p.shellLo.opacity(0.35), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                if p.pcb { PCBTraces().equatable() }
            }
        }
    }
}

private struct PCBTraces: View, Equatable {
    var body: some View {
        Canvas { ctx, size in
            let green = Color(.sRGB, red: 90 / 255, green: 220 / 255, blue: 150 / 255, opacity: 1)
            func line(_ a: CGPoint, _ b: CGPoint, _ o: Double) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(green.opacity(o)), lineWidth: 2)
            }
            let w = size.width, h = size.height
            line(CGPoint(x: w * 0.22, y: 0), CGPoint(x: w * 0.22, y: h), 0.07)
            line(CGPoint(x: 0, y: h * 0.41), CGPoint(x: w, y: h * 0.41), 0.06)
            line(CGPoint(x: w * 0.71, y: h * 0.41), CGPoint(x: w * 0.71, y: h), 0.05)
            for (pt, o) in [(CGPoint(x: w * 0.22, y: h * 0.41), 0.16), (CGPoint(x: w * 0.71, y: h * 0.72), 0.14)] {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(green.opacity(o)))
            }
        }
    }
}

// MARK: - Keys

private struct ToyKey: ToyLooking {
    let b: SkinButton
    let pressed: Bool
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOK: Bool { b.role == .ok }
    private var laserOn: Bool? { if case .toggle(let on) = b.role { return on } else { return nil } }

    var body: some View {
        let p = p
        let radius: CGFloat = isOK ? 26 : 20
        // A disabled key sits flush in its well with high-contrast text (ContentView fades it to 40%).
        let down = pressed || !b.enabled
        let capShape = RoundedRectangle(cornerRadius: radius - 3, style: .continuous)
        ZStack {
            ToyWell(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), p: p)
            ZStack(alignment: .top) {
                capShape.fill(isOK ? p.accentLo : p.rubberLo)
                    .padding(.top, 4)
                    .shadow(color: .black.opacity(down ? 0.25 : 0.38), radius: down ? 1 : 5, x: 0, y: down ? 1 : 6)
                face(p, shape: capShape, down: down)
                    .padding(.bottom, 4)
                    .scaleEffect(x: pressed ? 1.012 : 1, y: pressed ? 0.965 : 1, anchor: .bottom)
                    .offset(y: down ? 4 : 0)
            }
            .padding(3)
        }
        .animation(pressed ? .easeOut(duration: 0.05)
                   : (reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.42)),
                   value: pressed)
        .onChange(of: laserOn) { _, on in
            guard let on else { return }
            store.say(on ? "LASER ON  * pew" : "LASER OFF")
        }
    }

    @ViewBuilder
    private func face(_ p: ToyPalette, shape: RoundedRectangle, down: Bool) -> some View {
        if isOK {
            okFace(p, shape: shape, down: down)
        } else {
            let disabled = !b.enabled
            let fill = disabled
                ? AnyShapeStyle(p.rubberLo)
                : AnyShapeStyle(LinearGradient(stops: [.init(color: p.rubberHi, location: 0), .init(color: p.rubber, location: 0.45),
                                                       .init(color: p.rubber.mix(with: .black, by: 0.15), location: 1)],
                                               startPoint: .top, endPoint: .bottom))
            ZStack {
                shape.fill(fill)
                    .overlay(shape.fill(Color.black.opacity(0.001)
                        .shadow(.inner(color: .black.opacity(down ? 0.42 : 0.22), radius: down ? 4 : 2, x: 0, y: down ? 3 : -2))))
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(down ? 0.08 : 0.2), .clear],
                                                               startPoint: .top, endPoint: .center), lineWidth: 1.5))
                keyLabel(p, disabled: disabled)
                if let on = laserOn { bulb(on: on).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 9).padding(.trailing, 11) }
            }
        }
    }

    private func keyLabel(_ p: ToyPalette, disabled: Bool) -> some View {
        let tall = b.height >= 70
        var color: Color = disabled ? .white : p.rubberInk
        if laserOn == true { color = toyHex(0xFFD7D7) }
        let symbolColor: Color = b.id == "playpause" && !disabled ? p.accentHi : color
        return VStack(spacing: tall ? 6 : 4) {
            Image(systemName: b.symbol)
                .font(.system(size: tall ? 26 : 22, weight: .bold))
                .foregroundStyle(symbolColor)
            Text(b.label.uppercased())
                .font(ToyFont.rubik(tall ? 11 : 10, 800))
                .tracking(1.3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(color.opacity(disabled ? 1 : 0.88))
        }
        .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
        .padding(.horizontal, 6)
    }

    private func bulb(on: Bool) -> some View {
        Circle()
            .fill(on ? AnyShapeStyle(RadialGradient(colors: [.white, toyHex(0xFF3B3B), toyHex(0xAA0000)],
                                                    center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
                     : AnyShapeStyle(toyHex(0x4A1B1B).shadow(.inner(color: .black.opacity(0.5), radius: 1, y: 1))))
            .frame(width: 9, height: 9)
            .shadow(color: on ? toyHex(0xFF3B3B) : .clear, radius: 4)
            .shadow(color: on ? toyHex(0xFF3B3B).opacity(0.8) : .clear, radius: 1)
    }

    private func okFace(_ p: ToyPalette, shape: RoundedRectangle, down: Bool) -> some View {
        let size = min(44, b.height * 0.42)
        return ZStack {
            shape.fill(EllipticalGradient(stops: [.init(color: p.accentHi, location: 0), .init(color: p.accent, location: 0.5),
                                                  .init(color: p.accentLo, location: 1)],
                                          center: UnitPoint(x: 0.5, y: 0.2), startRadiusFraction: 0, endRadiusFraction: 0.85))
                .overlay(shape.fill(Color.black.opacity(0.001)
                    .shadow(.inner(color: .black.opacity(down ? 0.3 : 0.18), radius: down ? 5 : 3, x: 0, y: down ? 4 : -3))))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 2))
            // The dish: a shallow scoop for the thumb.
            GeometryReader { g in
                let dish = Capsule(style: .continuous)
                dish.fill(p.accentLo.opacity(0.12))
                    .overlay(dish.stroke(Color.black.opacity(0.28), lineWidth: 6).blur(radius: 3).offset(y: 2.5).mask(dish))
                    .overlay(dish.stroke(LinearGradient(colors: [.clear, .white.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .frame(width: g.size.width * 0.72, height: g.size.height * 0.76)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            Text(b.label.uppercased())
                .font(ToyFont.rubik(size, 800))
                .tracking(size * 0.06)
                .foregroundStyle(p.accentInk)
                .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: -1)
                .shadow(color: .white.opacity(0.3), radius: 0, x: 0, y: 1)
        }
    }
}

// MARK: - Touchpad

private struct ToyPad: ToyLooking {
    let s: PadState
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = p
        let surf = RoundedRectangle(cornerRadius: 23, style: .continuous)
        ZStack {
            ToyWell(shape: RoundedRectangle(cornerRadius: 28, style: .continuous), p: p, depth: 4)
            ZStack {
                surf.fill(LinearGradient(stops: [.init(color: p.pad.mix(with: .black, by: 0.15), location: 0),
                                                 .init(color: p.pad, location: 0.18), .init(color: p.pad, location: 1)],
                                         startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: .black.opacity(s.touching ? 0.38 : 0.25), radius: s.touching ? 7 : 4, x: 0, y: s.touching ? 5 : 3)))
                DotGrid(color: p.padDot, spacing: 12, radius: 1.1).equatable().clipShape(surf)
                surf.strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.16)], startPoint: .center, endPoint: .bottom), lineWidth: 1)
                GeometryReader { g in
                    Text("AIRPOINT")
                        .font(ToyFont.rubik(22, 800))
                        .tracking(7)
                        .foregroundStyle(p.padLogo)
                        .shadow(color: p.darkShell || p.pcb ? .black.opacity(0.6) : .white.opacity(0.45), radius: 0, x: 0, y: p.darkShell || p.pcb ? -1 : 1)
                        .position(x: g.size.width / 2, y: g.size.height * 0.44)
                }
                .accessibilityHidden(true)
                Text("Drag · tap · hold · 2-finger = back")
                    .font(ToyFont.rubik(12.5, 600))
                    .tracking(0.3)
                    .foregroundStyle(p.padHint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)
            }
            .padding(6)
            .animation(.easeOut(duration: 0.25), value: s.touching)
        }
        .overlay { dimple(p) }
    }

    private func dimple(_ p: ToyPalette) -> some View {
        GeometryReader { _ in
            if let loc = s.location {
                ZStack {
                    Circle()
                        .fill(RadialGradient(stops: [.init(color: .black.opacity(0.24), location: 0), .init(color: .black.opacity(0.12), location: 0.38 / 0.7),
                                                     .init(color: .white.opacity(0.08), location: 0.58 / 0.7), .init(color: .clear, location: 1)],
                                             center: .center, startRadius: 0, endRadius: 30))
                        .frame(width: 84, height: 84)
                        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.25, dampingFraction: 0.5)) {
                            $0.opacity(s.touching ? 1 : 0).scaleEffect(s.touching ? 1 : 0.6)
                        }
                    if s.touching && s.holdProgress > 0 {
                        Circle()
                            .trim(from: 0, to: s.holdProgress)
                            .stroke(p.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 66, height: 66)
                            .shadow(color: p.accent.opacity(Double(s.holdProgress)), radius: 8 * s.holdProgress)
                    }
                }
                .position(loc)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Thumbwheels

private struct ToyStrip: ToyLooking {
    let vertical: Bool
    let s: StripState
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let p = p
        let roll = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            ToyWell(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), p: p)
            ZStack {
                Canvas { ctx, size in
                    let period: CGFloat = 8
                    let length = vertical ? size.height : size.width
                    var o = s.travel.truncatingRemainder(dividingBy: period)
                    if o < 0 { o += period }
                    var t = o - period
                    while t < length {
                        for (start, len, color) in [(0.0, 2.0, p.rubberHi), (2.0, 4.0, p.rubber), (6.0, 2.0, p.rubberLo)] {
                            let a = t + CGFloat(start)
                            let r = vertical ? CGRect(x: 0, y: a, width: size.width, height: CGFloat(len))
                                             : CGRect(x: a, y: 0, width: CGFloat(len), height: size.height)
                            ctx.fill(Path(r), with: .color(color))
                        }
                        t += period
                    }
                }
                // Cylinder shading: dark at the ends of the wheel, a sheen across it.
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.2),
                                       .init(color: .clear, location: 0.8), .init(color: .black.opacity(0.55), location: 1)],
                               startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .white.opacity(0.12), location: 0.45),
                                       .init(color: .black.opacity(0.35), location: 1)],
                               startPoint: vertical ? .leading : .top, endPoint: vertical ? .trailing : .bottom)
            }
            .clipShape(roll)
            .brightness(s.touching ? 0.07 : 0)
            .padding(4)
            arrows(p)
        }
        .animation(.easeOut(duration: 0.15), value: s.touching)
    }

    private func arrows(_ p: ToyPalette) -> some View {
        let a = Image(systemName: vertical ? "arrowtriangle.up.fill" : "arrowtriangle.left.fill")
        let b = Image(systemName: vertical ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
        let layout = vertical ? AnyLayout(VStackLayout()) : AnyLayout(HStackLayout())
        return layout {
            a
            Spacer(minLength: 0)
            b
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(p.rubberInk.opacity(0.6))
        .padding(vertical ? .vertical : .horizontal, 11)
        .allowsHitTesting(false)
    }
}

// MARK: - Speed knob

private struct ToySpeed: ToyLooking {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragging = false
    @State private var last: CGSize = .zero
    @State private var acc: CGFloat = 0
    /// Already told the user this turn that the knob is at max.
    @State private var maxed = false
    @State private var honks = 0

    private static let names = ["CRAWL", "AMBLE", "TROT", "ZOOM", "HARE!"]
    private static let stops: [Double] = [0.4, 0.7, 1.0, 1.6, 2.5]
    private static let angles: [Double] = [-100, -50, 0, 50, 100]
    private let detentDistance: CGFloat = 22

    private var detents: [Double] { Self.stops.map { min(max($0, range.lowerBound), range.upperBound) } }
    private var index: Int {
        detents.indices.min { abs(detents[$0] - value) < abs(detents[$1] - value) } ?? 2
    }
    var body: some View {
        let p = p
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(p.label)
                .toyEmboss(p)
                .accessibilityHidden(true)
            knob(p)
            Image(systemName: "hare.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(p.label)
                .toyEmboss(p)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("SPEED")
                    .font(ToyFont.rubik(9.5, 800))
                    .tracking(1.6)
                Text("\(index + 1)·\(Self.names[index])")
                    .font(ToyFont.lcd(19))
                    .tracking(0.5)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(p.label)
            .toyEmboss(p)
            .frame(width: 60, alignment: .leading)
            .accessibilityHidden(true)
            grille(p)
        }
        .frame(height: 60)
    }

    private func knob(_ p: ToyPalette) -> some View {
        let angle = Self.angles[index]
        return ZStack {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i <= index ? p.accent : p.shellLo)
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: i <= index ? p.accent : .clear, radius: 3)
                    .offset(y: -27.5)
                    .rotationEffect(.degrees(Self.angles[i]))
            }
            ToyKnobCap(p: p)
                .rotationEffect(.degrees(angle))
                .frame(width: 42, height: 42)
                .shadow(color: p.rubberLo, radius: 0, x: 0, y: 4)
                .shadow(color: .black.opacity(0.4), radius: 5, x: 0, y: 7)
                .offset(y: -2)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: dragging ? 0.12 : 0.35, dampingFraction: 0.45),
                           value: angle)
        }
        .frame(width: 60, height: 60)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged(dragChanged)
                .onEnded { _ in
                    dragging = false
                    acc = 0
                    maxed = false
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Pointer speed")
        .accessibilityValue("\(index + 1) of 5, \(Self.names[index].capitalized)")
        .accessibilityHint("Turn right or drag up for faster, like a hare. Left or down for slower, like a tortoise.")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: set(index + 1)
            case .decrement: set(index - 1)
            @unknown default: break
            }
        }
    }

    private func dragChanged(_ g: DragGesture.Value) {
        if !dragging { dragging = true; last = .zero; acc = 0; maxed = false }
        // Right or up turns clockwise (faster).
        let d = (g.translation.width - last.width) - (g.translation.height - last.height)
        last = g.translation
        acc += d
        while acc >= detentDistance {
            acc -= detentDistance
            if index < 4 {
                set(index + 1)
            } else if !maxed {
                maxed = true
                store.say("MAX! IT DOESN'T GO TO 6", for: 1.6)
                Haptics.tap(.soft)
            }
        }
        while acc <= -detentDistance {
            acc += detentDistance
            maxed = false
            set(index - 1)
        }
    }

    private func set(_ i: Int) {
        let i = min(max(i, 0), 4)
        guard i != index else { return }
        value = detents[i]
        Haptics.tick()
        store.say("SPEED \(i + 1) · \(Self.names[i])")
    }

    private func grille(_ p: ToyPalette) -> some View {
        Button {
            honks += 1
            Haptics.tap(.light)
            store.say(honks % 5 == 0 ? "PLEASE STOP HONKING" : "HONK!")
        } label: {
            DotGrid(color: p.well, spacing: 9, radius: 2.1, highlight: p.shellHi.opacity(p.darkShell ? 0.5 : 1))
                .equatable()
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .overlay(alignment: .bottomTrailing) {
                    Text("AIRPOINT AP-1")
                        .font(ToyFont.rubik(8.5, 800))
                        .tracking(1.4)
                        .foregroundStyle(p.label)
                        .toyEmboss(p)
                        .fixedSize()
                        .offset(y: 13)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: reduceMotion ? 0 : honks) { content, s in
            content.scaleEffect(x: s.width, y: s.height)
        } keyframes: { _ in
            KeyframeTrack(\.width) { CubicKeyframe(1.06, duration: 0.12); SpringKeyframe(1, duration: 0.3, spring: .bouncy) }
            KeyframeTrack(\.height) { CubicKeyframe(0.88, duration: 0.12); SpringKeyframe(1, duration: 0.3, spring: .bouncy) }
        }
        .frame(minWidth: 40)
        .padding(.top, -10)
        .accessibilityLabel("Speaker grille")
    }
}

private struct ToyKnobCap: View {
    let p: ToyPalette

    var body: some View {
        ZStack {
            Knurl(a: p.rubber, b: p.rubberLo, count: 36, fraction: 0.3).equatable()
            Circle()
                .fill(RadialGradient(colors: [p.rubberHi, p.rubber], center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 22))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.35)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                .padding(5)
            Capsule()
                .fill(p.accent)
                .frame(width: 5, height: 12)
                .shadow(color: p.accent, radius: 2.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 7)
        }
    }
}

// MARK: - Header

private struct ToyLED: ToyLooking {
    let connected: Bool
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = p
        let led = connected ? toyHex(0x2BD36E) : toyHex(0xFFB020)
        ZStack {
            Circle()
                .fill(p.well.shadow(.inner(color: .black.opacity(0.45), radius: 2, y: 2)))
                .background(Circle().fill(p.shellHi).offset(y: 1))
                .frame(width: 20, height: 20)
            Group {
                if connected || reduceMotion {
                    bulb(led)
                } else {
                    bulb(led).phaseAnimator([1.0, 0.3]) { content, o in content.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
                }
            }
        }
        .padding(.trailing, 14)
        .accessibilityElement()
        .accessibilityLabel(connected ? "Connected" : "Not connected")
    }

    private func bulb(_ led: Color) -> some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: .white, location: 0), .init(color: led, location: 0.45),
                                         .init(color: led.mix(with: .black, by: 0.4), location: 1)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 7))
            .frame(width: 12, height: 12)
            .shadow(color: led, radius: 4)
            .shadow(color: led, radius: 1)
    }
}

/// The LCD window behind the TV name and status line. Insets line up with ToyLED and ToyGear.
private struct ToyLCDPanel: ToyLooking {
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let p = p
        let lcd = RoundedRectangle(cornerRadius: 14, style: .continuous)
        lcd.fill(p.lcd.shadow(.inner(color: .black.opacity(0.4), radius: 4, x: 0, y: 3)))
            .overlay(
                ZStack {
                    Canvas { ctx, size in
                        var y: CGFloat = 0
                        while y < size.height {
                            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.05)))
                            y += 3
                        }
                    }
                    LinearGradient(stops: [.init(color: .white.opacity(p.lcdGlow ? 0.07 : 0.22), location: 0), .init(color: .clear, location: 0.4)],
                                   startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
                }
                .clipShape(lcd)
                .allowsHitTesting(false)
            )
            .overlay(lcd.strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.well).padding(-4)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.shellHi).padding(-4).offset(y: 3))
            )
            .padding(.leading, 32)
            .padding(.trailing, 68)
    }
}

private struct ToySubtitle: ToyLooking {
    let status: String
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject private var fx: SkinFX
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = p
        let text = store.message ?? status
        Text(text)
            .font(ToyFont.lcd(18))
            .tracking(0.4)
            .foregroundStyle(p.lcdInk)
            .shadow(color: p.lcdGlow ? p.lcdInk.opacity(0.55) : .clear, radius: 3)
            .lineLimit(1)
            .truncationMode(.tail)
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : store.flash) { content, o in
                content.opacity(o)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.2)
                    LinearKeyframe(0.2, duration: 0.1)
                    MoveKeyframe(1.0)
                    LinearKeyframe(1.0, duration: 0.1)
                    MoveKeyframe(0.2)
                    LinearKeyframe(0.2, duration: 0.1)
                    MoveKeyframe(1.0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
            .onReceive(fx.$last.dropFirst()) { store.handle($0) }
            .accessibilityLabel(text)
    }
}

private struct ToyGear: ToyLooking {
    let pressed: Bool
    @ObservedObject var store = ToyStore.shared
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = p
        ZStack {
            Circle()
                .fill(p.well.shadow(.inner(color: .black.opacity(0.45), radius: 3, y: 3)))
                .background(Circle().fill(p.shellHi).offset(y: 1))
            ZStack {
                Knurl(a: p.rubber, b: p.rubberLo, count: 30, fraction: 0.5).equatable()
                Circle()
                    .fill(RadialGradient(colors: [p.rubberHi, p.rubberHi.mix(with: p.rubber, by: 0.5)], center: UnitPoint(x: 0.4, y: 0.3),
                                         startRadius: 0, endRadius: 14))
                    .scaleEffect(0.54)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(p.rubberInk)
            }
            .rotationEffect(.degrees(pressed ? 40 : 0))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .shadow(color: p.rubberLo, radius: 0, x: 0, y: pressed ? 1 : 4)
            .shadow(color: .black.opacity(0.35), radius: pressed ? 1 : 4, x: 0, y: pressed ? 1 : 5)
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 7, trailing: 4))
            .offset(y: pressed ? 3 : 0)
        }
        .frame(width: 54, height: 54)
        .animation(pressed ? .easeOut(duration: 0.06)
                   : (reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.4)),
                   value: pressed)
    }
}
