import SwiftUI

/// Placeholder: draws like PlainSkin until the Toy theme is built.
struct ToySkin: RemoteSkin {
    private let base = PlainSkin()
    var colorScheme: ColorScheme? { base.colorScheme }
    var tint: Color { base.tint }
    var ink: Color { base.ink }
    var inkSecondary: Color { base.inkSecondary }
    var titleFont: Font { base.titleFont }
    var captionFont: Font { base.captionFont }
    func backdrop() -> AnyView { base.backdrop() }
    func button(_ b: SkinButton, pressed: Bool) -> AnyView { base.button(b, pressed: pressed) }
    func pad(_ s: PadState) -> AnyView { base.pad(s) }
    func strip(vertical: Bool, _ s: StripState) -> AnyView { base.strip(vertical: vertical, s) }
    func speedControl(value: Binding<Double>, range: ClosedRange<Double>) -> AnyView { base.speedControl(value: value, range: range) }
    func statusDot(connected: Bool) -> AnyView { base.statusDot(connected: connected) }
    func subtitle(status: String) -> AnyView { base.subtitle(status: status) }
    func gear(pressed: Bool) -> AnyView { base.gear(pressed: pressed) }
}
