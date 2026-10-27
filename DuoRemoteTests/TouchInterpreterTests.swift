import Testing
import CoreGraphics
@testable import DuoRemote

@MainActor
struct TouchInterpreterTests {
    var t = TouchInterpreter()

    @Test mutating func tapClicksLeft() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        let out = t.update(touches: [:], time: 0.1)
        #expect(out == [.click(.left, at: nil)])
    }

    @Test mutating func directTapClicksAtFinger() {
        t.mode = .direct
        _ = t.update(touches: [0: CGPoint(x: 50, y: 60)], time: 0)
        #expect(t.update(touches: [:], time: 0.1) == [.click(.left, at: CGPoint(x: 50, y: 60))])
    }

    @Test mutating func slowLiftIsNotATap() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        #expect(t.update(touches: [:], time: 0.27).isEmpty)
    }

    @Test mutating func dragMovesPointer() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        let out = t.update(touches: [0: CGPoint(x: 120, y: 100)], time: 0.05)
        guard case let .pointerDelta(d, _)? = out.first else { Issue.record("no delta"); return }
        #expect(d == CGVector(dx: 20, dy: 0))
        #expect(t.update(touches: [:], time: 0.1).isEmpty)
    }

    @Test mutating func holdThenDragIsButtonDrag() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        #expect(t.tick(time: 0.2).isEmpty)
        #expect(t.tick(time: 0.31) == [.grabbed, .buttonDown(at: nil)])
        let move = t.update(touches: [0: CGPoint(x: 140, y: 100)], time: 0.4)
        guard case .pointerDelta? = move.first else { Issue.record("no move"); return }
        #expect(t.update(touches: [:], time: 0.5) == [.buttonUp])
    }

    @Test mutating func twoFingerTapIsRightClick() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 160, y: 100)], time: 0.02)
        let out = t.update(touches: [1: CGPoint(x: 160, y: 100)], time: 0.15)
        #expect(out == [.click(.right, at: nil)])
        #expect(t.update(touches: [:], time: 0.16).isEmpty)
    }

    @Test mutating func twoFingerDragScrolls() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 160, y: 100)], time: 0)
        let out = t.update(touches: [0: CGPoint(x: 100, y: 80), 1: CGPoint(x: 160, y: 80)], time: 0.05)
        #expect(out == [.scroll(CGVector(dx: 0, dy: -20))])
        let end = t.update(touches: [:], time: 0.1)
        guard case .scrollEnded? = end.first else { Issue.record("no scroll end"); return }
    }

    @Test mutating func closeFingersThatWobbleStillScroll() {
        // 40 pt apart; the gap wobbles to 46 pt (15%) while both fingers move up 14 pt.
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 140, y: 100)], time: 0)
        let out = t.update(touches: [0: CGPoint(x: 97, y: 86), 1: CGPoint(x: 143, y: 86)], time: 0.05)
        guard case .scroll? = out.first else { Issue.record("expected a scroll, got \(out)"); return }
    }

    @Test mutating func smallSpreadWithoutMovementWaits() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 140, y: 100)], time: 0)
        let out = t.update(touches: [0: CGPoint(x: 95, y: 100), 1: CGPoint(x: 145, y: 100)], time: 0.05)
        #expect(out.isEmpty)                                 // 10 pt of spread: not yet a pinch
    }

    @Test mutating func spreadingFingersPinches() {
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 200, y: 100)], time: 0)
        let out = t.update(touches: [0: CGPoint(x: 80, y: 100), 1: CGPoint(x: 220, y: 100)], time: 0.05)
        guard case let .zoom(f, anchor)? = out.first else { Issue.record("no zoom"); return }
        #expect(abs(f - 1.4) < 1e-9)
        #expect(anchor == CGPoint(x: 150, y: 100))
    }

    @Test mutating func threeFingersPan() {
        let a: [Int: CGPoint] = [0: CGPoint(x: 0, y: 0), 1: CGPoint(x: 30, y: 0), 2: CGPoint(x: 60, y: 0)]
        _ = t.update(touches: a, time: 0)
        let b = a.mapValues { CGPoint(x: $0.x + 15, y: $0.y + 5) }
        #expect(t.update(touches: b, time: 0.05) == [.pan(CGVector(dx: 15, dy: 5))])
    }

    @Test mutating func viewModeNeverClicks() {
        t.mode = .view
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        #expect(t.update(touches: [:], time: 0.1).isEmpty)                  // tap
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 1)
        #expect(t.tick(time: 1.5).isEmpty)                                   // hold
        #expect(t.update(touches: [:], time: 1.6).isEmpty)
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100), 1: CGPoint(x: 160, y: 100)], time: 2)
        #expect(t.update(touches: [:], time: 2.1).isEmpty)                  // two-finger tap
    }

    @Test mutating func viewModeDragMovesThePictureSideways() {
        t.mode = .view
        _ = t.update(touches: [0: CGPoint(x: 100, y: 100)], time: 0)
        #expect(t.update(touches: [0: CGPoint(x: 60, y: 102)], time: 0.05) == [.pan(CGVector(dx: -40, dy: 2))])
        guard case .panEnded? = t.update(touches: [:], time: 0.1).first else { Issue.record("no pan end"); return }
    }

    @Test func gainRampsWithSpeed() {
        #expect(InputController.gain(speed: 0) == 1)
        #expect(InputController.gain(speed: 5000) == 2.5)
    }
}
