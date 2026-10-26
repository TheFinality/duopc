@preconcurrency import RoyalVNCKit
import CoreGraphics
import Foundation
import QuartzCore

/// Applies touch intents: viewport maths → pointer moves, clicks, scroll steps, zoom/pan, and
/// momentum for scroll + pan. Owned by the canvas view; acts on the session.
final class InputController {
    struct Tuning {
        /// Points of finger travel per wheel click at 1× and slow speeds (fast swipes send up to
        /// 5× more). macOS turns each VNC wheel click into only a small scroll, so this is low;
        /// the session's scroll speed (global default or this Mac's override) divides it.
        var baseScrollPointsPerStep: CGFloat = 4
        var invertScroll = UserDefaults.standard.bool(forKey: "invertScroll")
        var momentumTimeConstant: CGFloat = 0.35
        var momentumMinSpeed: CGFloat = 300    // pt/s to start momentum
        var momentumStopSpeed: CGFloat = 20
    }

    var tuning = Tuning()
    private unowned let session: VNCSession
    private var scrollRemainder = CGVector.zero
    private var lastScrollTime: CFTimeInterval = 0
    private var scrollMomentum: CGVector?
    private var panMomentum: CGVector?
    var onGrab: (() -> Void)?
    var onClick: (() -> Void)?

    init(session: VNCSession) { self.session = session }

    var isAnimating: Bool { scrollMomentum != nil || panMomentum != nil }

    func stopMomentum() {
        scrollMomentum = nil
        panMomentum = nil
        scrollRemainder = .zero
    }

    func handle(_ intents: [TouchIntent]) {
        for i in intents { handle(i) }
    }

    private func handle(_ intent: TouchIntent) {
        let vp = session.viewport
        switch intent {
        case let .pointerDelta(d, speed):
            let g = Self.gain(speed: speed) / max(vp.scale, 0.0001)
            let p = CGPoint(x: session.pointer.x + d.dx * g, y: session.pointer.y + d.dy * g)
            session.movePointer(to: p)
            session.viewport.follow(session.pointer)
        case let .pointerAt(v):
            session.movePointer(to: vp.toContent(v))
        case let .click(button, at):
            if let at { session.movePointer(to: vp.toContent(at)) }
            session.click(button == .left ? .left : .right)
            onClick?()
        case let .buttonDown(at):
            if let at { session.movePointer(to: vp.toContent(at)) }
            session.buttonDown(.left)
        case .buttonUp:
            session.buttonUp(.left)
        case .grabbed:
            onGrab?()
        case let .scroll(d):
            let now = CACurrentMediaTime()
            let dt = max(now - lastScrollTime, 1.0 / 120)
            lastScrollTime = now
            scroll(by: d, speed: dt > 0.1 ? 0 : d.length / CGFloat(dt))
        case let .scrollEnded(v):
            scrollRemainder = .zero
            if v.length > tuning.momentumMinSpeed { scrollMomentum = v }
        case let .zoom(factor, anchor):
            session.viewport.zoom(by: factor, anchor: anchor)
        case let .pan(d):
            session.viewport.pan(by: d)
        case let .panEnded(v):
            if v.length > tuning.momentumMinSpeed { panMomentum = v }
        }
    }

    /// A mouse wheel or trackpad scroll: the system already adds its own momentum.
    func scrollWheel(by d: CGVector, speed: CGFloat) {
        scroll(by: d, speed: speed)
    }

    /// Advances momentum by `dt` seconds.
    func tick(dt: CGFloat) {
        let decay = exp(-dt / tuning.momentumTimeConstant)
        if var v = scrollMomentum {
            scroll(by: CGVector(dx: v.dx * dt, dy: v.dy * dt), speed: v.length)
            v = CGVector(dx: v.dx * decay, dy: v.dy * decay)
            scrollMomentum = v.length < tuning.momentumStopSpeed ? nil : v
        }
        if var v = panMomentum {
            session.viewport.pan(by: CGVector(dx: v.dx * dt, dy: v.dy * dt))
            v = CGVector(dx: v.dx * decay, dy: v.dy * decay)
            panMomentum = v.length < tuning.momentumStopSpeed ? nil : v
        }
    }

    /// Natural scrolling: fingers up (dy < 0) → content moves up → wheel down.
    private func scroll(by d: CGVector, speed: CGFloat) {
        let sign: CGFloat = (tuning.invertScroll ? -1 : 1) * Self.scrollGain(speed: speed)
        scrollRemainder.dx += d.dx * sign
        scrollRemainder.dy += d.dy * sign
        let step = tuning.baseScrollPointsPerStep / CGFloat(max(session.effectiveScrollSpeed, 0.25))
        let ySteps = Int(scrollRemainder.dy / step)
        let xSteps = Int(scrollRemainder.dx / step)
        if ySteps != 0 {
            session.scroll(ySteps < 0 ? .down : .up, steps: UInt32(abs(ySteps)))
            scrollRemainder.dy -= CGFloat(ySteps) * step
        }
        if xSteps != 0 {
            session.scroll(xSteps < 0 ? .right : .left, steps: UInt32(abs(xSteps)))
            scrollRemainder.dx -= CGFloat(xSteps) * step
        }
    }

    /// Scroll acceleration: 1× for slow, precise drags, up to 5× for fast swipes (pt/s).
    static func scrollGain(speed: CGFloat) -> CGFloat {
        let t = min(max((speed - 250) / 1500, 0), 1)
        return 1 + 4 * (t * t * (3 - 2 * t))
    }

    /// Pointer acceleration: 1× when slow, up to 2.5× when flicking.
    static func gain(speed: CGFloat) -> CGFloat {
        let t = min(max((speed - 200) / 1000, 0), 1)
        return 1 + 1.5 * (t * t * (3 - 2 * t))
    }
}

extension CGVector {
    var length: CGFloat { (dx * dx + dy * dy).squareRoot() }
}
