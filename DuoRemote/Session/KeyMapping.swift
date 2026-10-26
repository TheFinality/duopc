@preconcurrency import RoyalVNCKit

/// Text → X11 keysyms. (RoyalVNCKit's own helper is internal and drops newlines.)
enum KeyMapping {
    static func keyCodes(for text: String) -> [VNCKeyCode] {
        text.flatMap(keyCodes(for:))
    }

    /// Line breaks of every kind (CR LF, CR, LS, PS, NEL) as "\n", so no stray one becomes Return.
    static func normalizingLineBreaks(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r", "\u{2028}", "\u{2029}", "\u{85}": out.append("\n")
            case "\n": if !afterCR { out.append("\n") }
            default: out.append(scalar)
            }
            afterCR = scalar == "\r"
        }
        return String(out)
    }

    /// What Paste to Mac types: one entry per line, with leading and trailing line breaks dropped.
    static func pasteLines(_ text: String) -> [String] {
        let trimmed = normalizingLineBreaks(text).trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? [] : trimmed.components(separatedBy: "\n")
    }

    static let pasteConfirmLength = 2_000

    /// Multi-line or long pastes are confirmed first; short single lines go straight through.
    static func pasteNeedsConfirmation(_ lines: [String]) -> Bool {
        lines.count > 1 || lines.reduce(0) { $0 + $1.count } > pasteConfirmLength
    }

    static func keyCodes(for character: Character) -> [VNCKeyCode] {
        switch character {
        case "\n", "\r", "\r\n": return [.return]
        case "\t": return [.tab]
        default: break
        }
        return character.unicodeScalars.compactMap { scalar in
            let v = scalar.value
            switch v {
            case 0x20...0x7E, 0xA0...0xFF: return VNCKeyCode(v)          // Latin-1 keysyms == code points
            case 0..<0x20, 0x7F...0x9F: return nil                        // control characters
            default: return VNCKeyCode(0x0100_0000 | v)                   // X11 Unicode keysym
            }
        }
    }
}
