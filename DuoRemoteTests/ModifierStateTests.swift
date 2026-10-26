import Testing
@preconcurrency import RoyalVNCKit
@testable import DuoRemote

@MainActor
struct ModifierStateTests {
    @Test func latchedClearsAfterConsume() {
        let m = ModifierState()
        m.tap(.command)
        #expect(m.mode(of: .command) == .latched)
        #expect(m.consume() == [VNCKeyCode.command])
        #expect(m.mode(of: .command) == .off)
        #expect(m.consume().isEmpty)
    }

    @Test func lockedSurvivesConsume() {
        let m = ModifierState()
        m.lock(.shift)
        m.tap(.option)
        #expect(m.consume() == [VNCKeyCode.option, VNCKeyCode.shift])
        #expect(m.consume() == [VNCKeyCode.shift])
        m.tap(.shift)
        #expect(m.mode(of: .shift) == .off)
    }
}
