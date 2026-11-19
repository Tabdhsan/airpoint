import SwiftUI
import UIKit

// MARK: - Theme system
//
// ContentView owns layout, gestures and behaviour. A skin only draws things:
// the backdrop, buttons (pressed and not), the touchpad and strips, the speed control,
// header details, and a full-screen effects layer for flourishes and easter eggs.
// Skins learn what the user is doing through `SkinFX` events.

enum ThemeID: String, CaseIterable, Identifiable {
    case toy, zine, plain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toy: return "Toy Remote"
        case .zine: return "Chaos Zine"
        case .plain: return "Plain"
        }
    }
    var blurb: String {
        switch self {
        case .toy: return "Chunky molded plastic. Rubber keys, a click knob, thumbwheels."
        case .zine: return "Sticker-bombed riso zine. Wobbly, scribbly, a bit unhinged."
        case .plain: return "The quiet system look."
        }
    }
    var skin: any RemoteSkin {
        switch self {
        case .toy: return ToySkin()
        case .zine: return ZineSkin()
        case .plain: return PlainSkin()
        }
    }
}

/// What kind of button is being drawn. Skins usually style `.ok` as the hero.
enum SkinButtonRole: Equatable {
    case normal          // Back, Home, Type, Recenter
    case toggle(on: Bool) // Laser
    case media           // Rewind / Play-Pause / Forward
    case ok
}

struct SkinButton {
    /// Stable identifier, e.g. "back", "home", "type", "laser", "recenter", "ok", "rewind", "playpause", "forward".
    let id: String
    let symbol: String   // SF Symbol name
    let label: String
    let role: SkinButtonRole
    let enabled: Bool
    let height: CGFloat
}

struct PadState {
    var touching = false
    /// Finger position inside the pad (points), while touching.
    var location: CGPoint?
    var size: CGSize = .zero
    /// Long-press progress 0…1 while a still finger is held.
    var holdProgress: CGFloat = 0
}

struct StripState {
    var touching = false
    /// Accumulated travel along the strip's axis in points (drives ribs / textures).
    var travel: CGFloat = 0
}

/// User activity broadcast to the skin. Skins observe `last`/`count` for effects and easter eggs.
final class SkinFX: ObservableObject {
    enum Event: Equatable {
        case padDown, padUp
        case move(dx: CGFloat, dy: CGFloat)   // finger travel on the pad, points
        case click                            // pad tap or OK
        case longPress
        case step(dx: Int, dy: Int)           // D-pad step from a strip or two-finger scroll
        case stripUp                          // finger lifted off a scroll strip (ends a swipe of steps)
        case button(id: String)               // any themed button pressed
        case connected(Bool)
    }
    @Published private(set) var last: Event = .padUp
    @Published private(set) var count = 0

    func emit(_ e: Event) {
        last = e
        count &+= 1
    }
}

/// Whole-screen moves a skin can ask for. ContentView applies them to the layout and effects
/// (not the backdrop, so the screen edges stay covered).
final class ScreenFX: ObservableObject {
    static let shared = ScreenFX()
    @Published private(set) var rolls = 0
    func barrelRoll() { rolls &+= 1 }
}

private struct RollPose {
    var angle = 0.0    // spin in the screen plane, degrees
    var tilt = 0.0     // 3D lean while spinning, degrees
    var scale = 1.0
}

/// Two full turns: shrink, spin with a 3D lean, then land with a little bounce.
/// Reduce Motion: nothing moves.
struct BarrelRoll: ViewModifier {
    @ObservedObject private var screen = ScreenFX.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: RollPose(), trigger: reduceMotion ? 0 : screen.rolls) { view, p in
            view
                .rotation3DEffect(.degrees(p.tilt), axis: (x: 1, y: 0.4, z: 0), perspective: 0.6)
                .rotationEffect(.degrees(p.angle))
                .scaleEffect(p.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.62, duration: 0.3)
                LinearKeyframe(0.62, duration: 0.9)
                SpringKeyframe(1, duration: 0.6, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                LinearKeyframe(0, duration: 0.1)
                CubicKeyframe(720, duration: 1.2)
            }
            KeyframeTrack(\.tilt) {
                CubicKeyframe(35, duration: 0.5)
                CubicKeyframe(-25, duration: 0.5)
                SpringKeyframe(0, duration: 0.6, spring: .bouncy)
            }
        }
    }
}

/// Everything a theme draws. Every method returns a view; interactive pieces are noted.
protocol RemoteSkin {
    /// Forced color scheme, or nil to follow the system.
    var colorScheme: ColorScheme? { get }
    /// Accent used for system controls inside the screen (menus, sheets' tint).
    var tint: Color { get }
    /// Primary and secondary text colors on the backdrop.
    var ink: Color { get }
    var inkSecondary: Color { get }
    var titleFont: Font { get }      // TV name
    var captionFont: Font { get }    // status line, small labels

    /// Full-screen background, edge to edge (ignores safe area).
    func backdrop() -> AnyView
    /// Button face. Not interactive: the button's hit area is handled by ContentView.
    func button(_ b: SkinButton, pressed: Bool) -> AnyView
    /// Touchpad surface behind the gesture layer. Not interactive.
    func pad(_ s: PadState) -> AnyView
    /// Scroll strip surface. Not interactive.
    func strip(vertical: Bool, _ s: StripState) -> AnyView
    /// Pointer speed control. INTERACTIVE: must write `value` within `range`.
    func speedControl(value: Binding<Double>, range: ClosedRange<Double>) -> AnyView
    /// Connection light in the header.
    func statusDot(connected: Bool) -> AnyView
    /// Header subtitle. May be interactive (e.g. tap-to-cycle jokes); must show `status` by default.
    func subtitle(status: String) -> AnyView
    /// Gear button face (the tap is handled by ContentView). `pressed` while held.
    func gear(pressed: Bool) -> AnyView
    /// Optional decoration behind the whole header (e.g. an LCD panel). Not interactive.
    func headerPanel() -> AnyView
    /// Full-screen effects layer above everything. Not interactive (hit testing is off).
    func effects() -> AnyView
}

extension RemoteSkin {
    func headerPanel() -> AnyView { AnyView(EmptyView()) }
    func effects() -> AnyView { AnyView(EmptyView()) }
}

// MARK: - Button style that hands the face to the skin

struct SkinButtonStyle: ButtonStyle {
    let skin: any RemoteSkin
    let spec: SkinButton

    func makeBody(configuration: Configuration) -> some View {
        skin.button(spec, pressed: configuration.isPressed)
            // Fixed height: skins fill this box; the pad, not the buttons, takes spare space.
            .frame(maxWidth: .infinity, minHeight: spec.height, maxHeight: spec.height)
            .contentShape(Rectangle())
            .opacity(spec.enabled ? 1 : 0.4)
    }
}

/// Haptic used for every themed button press.
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Plain (the original look)

struct PlainSkin: RemoteSkin {
    var colorScheme: ColorScheme? { nil }
    var tint: Color { .accentColor }
    var ink: Color { .primary }
    var inkSecondary: Color { .secondary }
    var titleFont: Font { .headline }
    var captionFont: Font { .caption }

    func backdrop() -> AnyView { AnyView(Color(.systemBackground)) }

    func button(_ b: SkinButton, pressed: Bool) -> AnyView {
        let prominent = b.role == .ok
        let highlighted: Bool = {
            if case .toggle(let on) = b.role { return on }
            return b.id == "playpause"
        }()
        return AnyView(
            VStack(spacing: 4) {
                Image(systemName: b.symbol).font(prominent ? .largeTitle : .title2)
                Text(b.label).font(prominent ? .caption.weight(.semibold) : .caption2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(prominent ? Color.white : (highlighted ? Color.accentColor : Color.primary))
            .background(prominent ? Color.accentColor : (highlighted ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
        )
    }

    func pad(_ s: PadState) -> AnyView {
        AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemBackground))
                VStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left").font(.system(size: 34))
                    Text("Drag to move · tap to click · hold for long press\nTwo-finger tap for Back")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            }
        )
    }

    func strip(vertical: Bool, _ s: StripState) -> AnyView {
        AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(.separator)))
                Image(systemName: vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        )
    }

    func speedControl(value: Binding<Double>, range: ClosedRange<Double>) -> AnyView {
        AnyView(
            HStack(spacing: 10) {
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: value, in: range)
                Image(systemName: "hare").foregroundStyle(.secondary)
            }
            .font(.footnote)
        )
    }

    func statusDot(connected: Bool) -> AnyView {
        AnyView(Circle().fill(connected ? Color.green : Color.orange).frame(width: 10, height: 10))
    }

    func subtitle(status: String) -> AnyView {
        AnyView(Text(status).font(.caption).foregroundStyle(.secondary))
    }

    func gear(pressed: Bool) -> AnyView {
        AnyView(
            Image(systemName: "gearshape")
                .font(.title3)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: Circle())
                .scaleEffect(pressed ? 0.92 : 1)
        )
    }
}
