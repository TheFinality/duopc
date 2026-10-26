import CoreGraphics
import Foundation

/// What a touch sequence means, before any coordinate maths. Locations are view points.
enum TouchIntent: Equatable {
    /// Trackpad: move the pointer by a finger delta; `speed` (pt/s) drives acceleration.
    case pointerDelta(CGVector, speed: CGFloat)
    /// Direct: put the pointer under the finger.
    case pointerAt(CGPoint)
    /// Click; `at` is the finger location in direct mode, nil = at the current pointer.
    case click(Button, at: CGPoint?)
    case buttonDown(at: CGPoint?)
    case buttonUp
    /// Two-finger scroll: centroid delta.
    case scroll(CGVector)
    case scrollEnded(velocity: CGVector)
    case zoom(factor: CGFloat, anchor: CGPoint)
    case pan(CGVector)
    case panEnded(velocity: CGVector)
    case grabbed   // hold recognised → haptic

    enum Button: Equatable { case left, right }
}

/// Turns raw touches into intents. Pure state machine: feed it the full set of active touches
/// after every UIKit touch callback (`update`) and once per display frame (`tick`, for the hold
/// timer). Time is injected so tests can drive it.
struct TouchInterpreter {
    struct Thresholds {
        var slop: CGFloat = 8              // pt a finger may wander and still be a tap/hold
        var tapMaxDuration: TimeInterval = 0.25
        var holdDuration: TimeInterval = 0.30
        var twoFingerTapMaxDuration: TimeInterval = 0.30
        var pinchCommitLogRatio: CGFloat = 0.10
        var scrollCommitDistance: CGFloat = 10
    }

    var mode: InputMode = .trackpad
    var thresholds = Thresholds()

    private enum State {
        case idle
        case oneDown(id: Int, start: CGPoint, last: CGPoint, t0: TimeInterval)
        case oneMoving(id: Int, last: CGPoint)
        case holding(id: Int, last: CGPoint)
        case twoDown(ids: Set<Int>, c0: CGPoint, span0: CGFloat, t0: TimeInterval)
        case pinching(ids: Set<Int>, lastC: CGPoint, lastSpan: CGFloat)
        case scrolling(ids: Set<Int>, lastC: CGPoint)
        case threePan(ids: Set<Int>, lastC: CGPoint)
        case finishing    // ignore everything until all fingers lift
    }

    private var state: State = .idle
    private var velocity = VelocityTracker()

    var isIdle: Bool { if case .idle = state { true } else { false } }

    mutating func update(touches: [Int: CGPoint], time t: TimeInterval) -> [TouchIntent] {
        let n = touches.count
        var out: [TouchIntent] = []

        switch state {
        case .idle:
            begin(touches, t)

        case let .oneDown(id, start, _, t0):
            if n == 0 {
                if t - t0 <= thresholds.tapMaxDuration {
                    out.append(.click(.left, at: mode == .direct ? start : nil))
                }
                state = .idle
            } else if n == 1, let p = touches[id] {
                if p.distance(to: start) > thresholds.slop {
                    state = .oneMoving(id: id, last: p)
                    velocity.reset(p, t)
                    out += oneFingerMove(from: start, to: p, t: t)
                } else {
                    state = .oneDown(id: id, start: start, last: p, t0: t0)
                }
            } else {
                begin(touches, t)   // a second (or third) finger joined before we committed
            }

        case let .oneMoving(id, last):
            if n == 1, let p = touches[id] {
                velocity.add(p, t)
                out += oneFingerMove(from: last, to: p, t: t)
                state = .oneMoving(id: id, last: p)
            } else {
                if mode == .direct { out.append(.panEnded(velocity: n == 0 ? velocity.velocity : .zero)) }
                state = n == 0 ? .idle : .finishing
            }

        case let .holding(id, last):
            if n == 1, let p = touches[id] {
                velocity.add(p, t)
                if mode == .direct {
                    out.append(.pointerAt(p))
                } else {
                    out.append(.pointerDelta(CGVector(dx: p.x - last.x, dy: p.y - last.y), speed: velocity.speed))
                }
                state = .holding(id: id, last: p)
            } else {
                out.append(.buttonUp)
                state = n == 0 ? .idle : .finishing
            }

        case let .twoDown(ids, c0, span0, t0):
            if n == 2, Set(touches.keys) == ids {
                let c = centroid(touches), s = span(touches)
                if span0 > 0, abs(log(s / span0)) > thresholds.pinchCommitLogRatio {
                    out.append(.zoom(factor: s / span0, anchor: c))
                    out.append(.pan(CGVector(dx: c.x - c0.x, dy: c.y - c0.y)))
                    state = .pinching(ids: ids, lastC: c, lastSpan: s)
                } else if c.distance(to: c0) > thresholds.scrollCommitDistance {
                    velocity.reset(c, t)
                    out.append(.scroll(CGVector(dx: c.x - c0.x, dy: c.y - c0.y)))
                    state = .scrolling(ids: ids, lastC: c)
                }
            } else if n < 2 {
                if t - t0 <= thresholds.twoFingerTapMaxDuration {
                    out.append(.click(.right, at: mode == .direct ? c0 : nil))
                }
                state = n == 0 ? .idle : .finishing
            } else if n >= 3 {
                begin(touches, t)
            } else {
                begin(touches, t)   // same count, different fingers: rebase
            }

        case let .pinching(ids, lastC, lastSpan):
            if n == 2, Set(touches.keys) == ids {
                let c = centroid(touches), s = span(touches)
                if lastSpan > 0 { out.append(.zoom(factor: s / lastSpan, anchor: c)) }
                out.append(.pan(CGVector(dx: c.x - lastC.x, dy: c.y - lastC.y)))
                state = .pinching(ids: ids, lastC: c, lastSpan: s)
            } else {
                state = n == 0 ? .idle : .finishing
            }

        case let .scrolling(ids, lastC):
            if n == 2, Set(touches.keys) == ids {
                let c = centroid(touches)
                velocity.add(c, t)
                out.append(.scroll(CGVector(dx: c.x - lastC.x, dy: c.y - lastC.y)))
                state = .scrolling(ids: ids, lastC: c)
            } else {
                out.append(.scrollEnded(velocity: n == 0 || n == 1 ? velocity.velocity : .zero))
                state = n == 0 ? .idle : .finishing
            }

        case let .threePan(ids, lastC):
            if n >= 3 {
                let c = centroid(touches)
                if Set(touches.keys) == ids {
                    velocity.add(c, t)
                    out.append(.pan(CGVector(dx: c.x - lastC.x, dy: c.y - lastC.y)))
                } else {
                    velocity.reset(c, t)
                }
                state = .threePan(ids: Set(touches.keys), lastC: c)
            } else {
                out.append(.panEnded(velocity: velocity.velocity))
                state = n == 0 ? .idle : .finishing
            }

        case .finishing:
            if n == 0 { state = .idle }
        }
        return out
    }

    /// Call once per frame: fires the hold → button-down transition.
    mutating func tick(time t: TimeInterval) -> [TouchIntent] {
        guard case let .oneDown(id, start, last, t0) = state, t - t0 >= thresholds.holdDuration else { return [] }
        state = .holding(id: id, last: last)
        velocity.reset(last, t)
        return [.grabbed, .buttonDown(at: mode == .direct ? start : nil)]
    }

    /// Touches were cancelled by the system: release anything held.
    mutating func cancel() -> [TouchIntent] {
        defer { state = .idle }
        if case .holding = state { return [.buttonUp] }
        return []
    }

    // MARK: Helpers

    private mutating func begin(_ touches: [Int: CGPoint], _ t: TimeInterval) {
        switch touches.count {
        case 0: state = .idle
        case 1:
            let (id, p) = touches.first!
            state = .oneDown(id: id, start: p, last: p, t0: t)
        case 2:
            state = .twoDown(ids: Set(touches.keys), c0: centroid(touches), span0: span(touches), t0: t)
        default:
            let c = centroid(touches)
            velocity.reset(c, t)
            state = .threePan(ids: Set(touches.keys), lastC: c)
        }
    }

    private func oneFingerMove(from a: CGPoint, to b: CGPoint, t: TimeInterval) -> [TouchIntent] {
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        return mode == .direct ? [.pan(d)] : [.pointerDelta(d, speed: velocity.speed)]
    }

    private func centroid(_ touches: [Int: CGPoint]) -> CGPoint {
        let ps = touches.values
        let n = CGFloat(max(ps.count, 1))
        return CGPoint(x: ps.reduce(0) { $0 + $1.x } / n, y: ps.reduce(0) { $0 + $1.y } / n)
    }

    /// Distance between the two touches (pinch span). Uses the first two by id.
    private func span(_ touches: [Int: CGPoint]) -> CGFloat {
        let ps = touches.sorted { $0.key < $1.key }.map(\.value)
        guard ps.count >= 2 else { return 0 }
        return ps[0].distance(to: ps[1])
    }
}

/// Velocity over the last ~80 ms of samples.
struct VelocityTracker {
    private var samples: [(p: CGPoint, t: TimeInterval)] = []

    mutating func reset(_ p: CGPoint, _ t: TimeInterval) { samples = [(p, t)] }

    mutating func add(_ p: CGPoint, _ t: TimeInterval) {
        samples.append((p, t))
        while samples.count > 2, t - samples[0].t > 0.08 { samples.removeFirst() }
    }

    var velocity: CGVector {
        guard let first = samples.first, let last = samples.last, last.t - first.t > 0.001 else { return .zero }
        let dt = CGFloat(last.t - first.t)
        return CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
    }

    var speed: CGFloat { let v = velocity; return (v.dx * v.dx + v.dy * v.dy).squareRoot() }
}

extension CGPoint {
    func distance(to o: CGPoint) -> CGFloat { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}
