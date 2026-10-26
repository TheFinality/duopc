import Testing
@preconcurrency import RoyalVNCKit
@testable import DuoRemote

@MainActor
struct ModifierStateTests {
    @Test func latchedClearsAfterConsume() {
        let m = ModifierState()
        m.tap(.windows)
        #expect(m.mode(of: .windows) == .latched)
        #expect(m.consume() == [VNCKeyCode.command])
        #expect(m.mode(of: .windows) == .off)
        #expect(m.consume().isEmpty)
    }

    @Test func lockedSurvivesConsume() {
        let m = ModifierState()
        m.lock(.shift)
        m.tap(.alt)
        #expect(m.consume() == [VNCKeyCode.option, VNCKeyCode.shift])
        #expect(m.consume() == [VNCKeyCode.shift])
        m.tap(.shift)
        #expect(m.mode(of: .shift) == .off)
    }

    @Test func pcModifiersSendWindowsKeysInKeyboardOrder() {
        #expect(Modifier.allCases == [.control, .windows, .alt, .shift])
        #expect(Modifier.windows.keyCode == VNCKeyCode.command)   // XK_Super_L → Windows key
        #expect(Modifier.alt.keyCode == VNCKeyCode.option)        // XK_Alt_L
        let m = ModifierState()
        m.tap(.shift)
        m.tap(.control)
        #expect(m.consume() == [VNCKeyCode.control, VNCKeyCode.shift])
    }
}
