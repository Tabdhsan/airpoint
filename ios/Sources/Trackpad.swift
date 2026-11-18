import SwiftUI
import UIKit

/// Laptop-style trackpad: one finger moves, tap clicks, hold long-presses,
/// two fingers scroll, two-finger tap goes back.
final class TrackpadView: UIView {
    enum Event {
        case began                      // first finger down
        case ended                      // last finger up
        case move(CGFloat, CGFloat)     // pointer delta in points
        case scroll(CGFloat, CGFloat)   // two-finger delta in points
        case tap, longPress, twoFingerTap
    }

    var onEvent: ((Event) -> Void)?
    /// Finger (centroid) position while touching, nil when lifted. For skins only.
    var onLocation: ((CGPoint?) -> Void)?

    private var active = Set<UITouch>()
    private var maxFingers = 0
    private var startTime = Date()
    private var travel: CGFloat = 0
    private var longPressFired = false
    private var longPressWork: DispatchWorkItem?
    private var lastCentroid = CGPoint.zero
    private var lastMoveTime = CACurrentMediaTime()
    private let moveThreshold: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in active { let p = t.location(in: self); x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(active.count), y: y / CGFloat(active.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasEmpty = active.isEmpty
        active.formUnion(touches)
        maxFingers = max(maxFingers, active.count)
        lastCentroid = centroid()
        onLocation?(lastCentroid)
        if wasEmpty {
            maxFingers = active.count
            startTime = Date()
            travel = 0
            longPressFired = false
            lastMoveTime = CACurrentMediaTime()
            onEvent?(.began)
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.active.isEmpty, self.maxFingers == 1, self.travel < self.moveThreshold else { return }
                self.longPressFired = true
                self.onEvent?(.longPress)
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let c = centroid()
        let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
        lastCentroid = c
        onLocation?(c)
        travel += hypot(dx, dy)
        guard travel >= moveThreshold, !longPressFired else { return }
        longPressWork?.cancel()
        if active.count >= 2 {
            onEvent?(.scroll(dx, dy))
        } else if maxFingers == 1 {
            onEvent?(.move(dx, dy))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        active.subtract(touches)
        lastCentroid = centroid()
        guard active.isEmpty else { return }
        onLocation?(nil)
        longPressWork?.cancel()
        let quick = Date().timeIntervalSince(startTime) < 0.35
        if !longPressFired, travel < moveThreshold, quick {
            onEvent?(maxFingers >= 2 ? .twoFingerTap : .tap)
        }
        onEvent?(.ended)
    }
}

struct Trackpad: UIViewRepresentable {
    let onEvent: (TrackpadView.Event) -> Void
    var onLocation: ((CGPoint?) -> Void)? = nil

    func makeUIView(context: Context) -> TrackpadView {
        let view = TrackpadView()
        view.onEvent = onEvent
        view.onLocation = onLocation
        return view
    }

    func updateUIView(_ view: TrackpadView, context: Context) {
        view.onEvent = onEvent
        view.onLocation = onLocation
    }
}
