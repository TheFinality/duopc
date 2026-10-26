@preconcurrency import RoyalVNCKit
import UIKit

/// Hardware keyboard (USB HID usage, as UIKit reports it) → VNC key. Letters and punctuation map to
/// their unshifted keysyms; Shift travels as its own modifier key and macOS applies it.
enum HIDKeyMap {
    static func key(for usage: UIKeyboardHIDUsage) -> VNCKeyCode? {
        key(forUsageRawValue: usage.rawValue)
    }

    private static func ascii(_ c: Character) -> VNCKeyCode {
        VNCKeyCode(asciiCharacter: c.asciiValue!)
    }

    /// Raw HID Keyboard/Keypad page (0x07) usage IDs.
    static func key(forUsageRawValue raw: Int) -> VNCKeyCode? {
        switch raw {
        case 0x04...0x1D:                       // a–z
            return VNCKeyCode(asciiCharacter: UInt8(97 + raw - 0x04))
        case 0x1E...0x26:                       // 1–9
            return VNCKeyCode(asciiCharacter: UInt8(49 + raw - 0x1E))
        case 0x27: return ascii("0")
        case 0x28: return .return
        case 0x29: return .escape
        case 0x2A: return .delete               // Backspace
        case 0x2B: return .tab
        case 0x2C: return .space
        case 0x2D: return ascii("-")
        case 0x2E: return ascii("=")
        case 0x2F: return ascii("[")
        case 0x30: return ascii("]")
        case 0x31: return ascii("\\")
        case 0x33: return ascii(";")
        case 0x34: return ascii("'")
        case 0x35: return ascii("`")
        case 0x36: return ascii(",")
        case 0x37: return ascii(".")
        case 0x38: return ascii("/")
        case 0x3A: return .f1
        case 0x3B: return .f2
        case 0x3C: return .f3
        case 0x3D: return .f4
        case 0x3E: return .f5
        case 0x3F: return .f6
        case 0x40: return .f7
        case 0x41: return .f8
        case 0x42: return .f9
        case 0x43: return .f10
        case 0x44: return .f11
        case 0x45: return .f12
        case 0x49: return .insert
        case 0x4A: return .home
        case 0x4B: return .pageUp
        case 0x4C: return .forwardDelete
        case 0x4D: return .end
        case 0x4E: return .pageDown
        case 0x4F: return .rightArrow
        case 0x50: return .leftArrow
        case 0x51: return .downArrow
        case 0x52: return .upArrow
        case 0x54: return .ansiKeypadDivide
        case 0x55: return .ansiKeypadMultiply
        case 0x56: return .ansiKeypadMinus
        case 0x57: return .ansiKeypadPlus
        case 0x58: return .ansiKeypadEnter
        case 0x59...0x61:                       // keypad 1–9
            return VNCKeyCode(asciiCharacter: UInt8(49 + raw - 0x59))
        case 0x62: return ascii("0")
        case 0x63: return ascii(".")
        case 0x67: return .ansiKeypadEquals
        case 0xE0: return .control
        case 0xE1: return .shift
        case 0xE2: return .option
        case 0xE3: return .command
        case 0xE4: return .rightControl
        case 0xE5: return .rightShift
        case 0xE6: return .rightOption
        case 0xE7: return .rightCommand
        default: return nil
        }
    }
}
