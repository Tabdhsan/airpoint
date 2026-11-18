import CoreMotion
import Foundation

/// Turns the phone's rotation into pointer motion.
///
/// Horizontal motion is rotation about the world's vertical axis (gravity), so turning
/// the phone left moves the pointer left however the phone is rolled. Vertical motion is
/// rotation about the horizontal axis perpendicular to where the top of the phone points.
final class MotionPointer {
    enum Mode { case mouse, aim, off }

    /// Called on the motion queue.
    var onMove: ((Float, Float) -> Void)?
    var onPosition: ((Float, Float) -> Void)?

    // Written from the main thread, read on the motion queue; single-word values.
    var mode: Mode = .mouse
    var sensitivity: Double = 1.0
    var frozen = false

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var lastTimestamp: TimeInterval = 0
    private var smoothed = (yaw: 0.0, pitch: 0.0)
    private var remainder = (x: 0.0, y: 0.0)
    private var aim = (yaw: 0.0, pitch: 0.0)       // radians from the recentered direction
    private var recenterRequested = false
    private var lastSent = (x: Float(-1), y: Float(-1))
    /// After D-pad navigation, stay quiet until the phone clearly moves (ignores hand tremor).
    private var quietAnchor: (x: Float, y: Float)?

    func quietUntilMoved() {
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.quietAnchor = self.lastSent.x >= 0 ? self.lastSent : nil
            self.remainder = (0, 0)
        }
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        lastTimestamp = 0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.process(motion)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Aim mode: shifts where the phone points on screen by a pad drag (reference pixels).
    func nudge(dx: Double, dy: Double) {
        queue.addOperation { [weak self] in
            guard let self else { return }
            let spanX = (24.0 * .pi / 180) / self.sensitivity
            self.aim.yaw += dx / 1920 * spanX
            self.aim.pitch -= dy / 1080 * spanX * 9 / 16
            let wasFrozen = self.frozen
            self.frozen = false
            self.aimAt(dt: 0)
            self.frozen = wasFrozen
        }
    }

    /// Aim mode: the current direction becomes the screen center.
    func recenter() { queue.addOperation { [weak self] in self?.recenterRequested = true } }

    private func process(_ m: CMDeviceMotion) {
        let dt = lastTimestamp == 0 ? 0.01 : min(max(m.timestamp - lastTimestamp, 0.001), 0.05)
        lastTimestamp = m.timestamp

        // Unit "up" in the device frame (gravity points down).
        let g = m.gravity
        let gl = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard gl > 0.3 else { return }
        let up = (x: -g.x / gl, y: -g.y / gl, z: -g.z / gl)
        let w = m.rotationRate

        // Rotation about "up", negated: positive = turning right.
        let yawRate = -(w.x * up.x + w.y * up.y + w.z * up.z)
        // Pitch axis = device +Y × up = (up.z, 0, -up.x); falls back to device X when degenerate.
        var h = (x: up.z, z: -up.x)
        let hl = (h.x * h.x + h.z * h.z).squareRoot()
        if hl < 0.2 { h = (1, 0) } else { h = (h.x / hl, h.z / hl) }
        let pitchRate = w.x * h.x + w.z * h.z     // positive = top of phone tilting up

        // Light smoothing against hand tremor.
        smoothed.yaw += (yawRate - smoothed.yaw) * 0.5
        smoothed.pitch += (pitchRate - smoothed.pitch) * 0.5

        if recenterRequested {
            recenterRequested = false
            aim = (0, 0)
            remainder = (0, 0)
            lastSent = (-1, -1)
            quietAnchor = nil
        }

        switch mode {
        case .off:
            return
        case .mouse:
            mouse(dt: dt)
        case .aim:
            aimAt(dt: dt)
        }
    }

    private func mouse(dt: Double) {
        let speed = (smoothed.yaw * smoothed.yaw + smoothed.pitch * smoothed.pitch).squareRoot()
        let deadZone = 0.02
        guard speed > deadZone, !frozen else { remainder = (0, 0); return }
        let soft = (speed - deadZone) / speed
        // Slow movements are precise, fast ones cover the screen: ~1600 to ~7200 px per radian.
        let t = min(max((speed - 0.08) / 1.6, 0), 1)
        let accel = 0.55 + 1.95 * t * t * (3 - 2 * t)
        let gain = 2900 * sensitivity * accel * soft
        remainder.x += smoothed.yaw * gain * dt
        remainder.y += -smoothed.pitch * gain * dt
        let sx = remainder.x.rounded(.towardZero), sy = remainder.y.rounded(.towardZero)
        guard sx != 0 || sy != 0 else { return }
        remainder.x -= sx
        remainder.y -= sy
        onMove?(Float(sx), Float(sy))
    }

    private func aimAt(dt: Double) {
        // Integrate even while frozen so the pointer stays where the phone actually points.
        aim.yaw += smoothed.yaw * dt
        aim.pitch += smoothed.pitch * dt
        guard !frozen else { return }
        // The screen spans about 24° wide at sensitivity 1 (matches the old Air mode speed); higher sensitivity = smaller wrist motion.
        let spanX = (24.0 * .pi / 180) / sensitivity
        let spanY = spanX * 9 / 16
        let x = min(max(0.5 + aim.yaw / spanX, 0), 1)
        let y = min(max(0.5 - aim.pitch / spanY, 0), 1)
        let p = (x: Float(x), y: Float(y))
        if let anchor = quietAnchor {
            guard abs(p.x - anchor.x) > 0.04 || abs(p.y - anchor.y) > 0.04 else { return }
            quietAnchor = nil
        }
        guard abs(p.x - lastSent.x) > 0.0003 || abs(p.y - lastSent.y) > 0.0003 else { return }
        lastSent = p
        onPosition?(p.x, p.y)
    }
}
