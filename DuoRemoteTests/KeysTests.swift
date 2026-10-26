import Testing
import UIKit
@preconcurrency import RoyalVNCKit
@testable import DuoRemote

@MainActor
struct KeysTests {
    @Test func hidKeyMapSpotChecks() {
        #expect(HIDKeyMap.key(for: .keyboardA) == VNCKeyCode(asciiCharacter: UInt8(ascii: "a")))
        #expect(HIDKeyMap.key(for: .keyboardZ) == VNCKeyCode(asciiCharacter: UInt8(ascii: "z")))
        #expect(HIDKeyMap.key(for: .keyboard1) == VNCKeyCode(asciiCharacter: UInt8(ascii: "1")))
        #expect(HIDKeyMap.key(for: .keyboard0) == VNCKeyCode(asciiCharacter: UInt8(ascii: "0")))
        #expect(HIDKeyMap.key(for: .keyboardSlash) == VNCKeyCode(asciiCharacter: UInt8(ascii: "/")))
        #expect(HIDKeyMap.key(for: .keyboardReturnOrEnter) == VNCKeyCode.return)
        #expect(HIDKeyMap.key(for: .keyboardLeftArrow) == VNCKeyCode.leftArrow)
        #expect(HIDKeyMap.key(for: .keyboardLeftGUI) == VNCKeyCode.command)
        #expect(HIDKeyMap.key(for: .keyboardRightGUI) == VNCKeyCode.rightCommand)
        #expect(HIDKeyMap.key(for: .keyboardF5) == VNCKeyCode.f5)
        #expect(HIDKeyMap.key(for: .keyboardDeleteOrBackspace) == VNCKeyCode.delete)
        #expect(HIDKeyMap.key(for: .keyboardDeleteForward) == VNCKeyCode.forwardDelete)
    }

    @Test func doubleTapWithinWindowLocks() {
        let first = (modifier: Modifier.command, time: 10.0)
        #expect(ModifierTap.decide(previous: nil, modifier: .command, now: 10.0) == .tap)
        #expect(ModifierTap.decide(previous: first, modifier: .command, now: 10.2) == .lock)
    }

    @Test func slowOrDifferentKeyTapsAgain() {
        let first = (modifier: Modifier.command, time: 10.0)
        #expect(ModifierTap.decide(previous: first, modifier: .command, now: 10.5) == .tap)
        #expect(ModifierTap.decide(previous: first, modifier: .shift, now: 10.1) == .tap)
    }

    @Test func modifierKeyTapsLatchLockAndRelease() {
        let m = ModifierState()
        m.keyTapped(.command, now: 10.0)
        #expect(m.mode(of: .command) == .latched)
        m.keyTapped(.command, now: 10.2)
        #expect(m.mode(of: .command) == .locked)
        m.keyTapped(.command, now: 11.0)
        #expect(m.mode(of: .command) == .off)
    }
}
