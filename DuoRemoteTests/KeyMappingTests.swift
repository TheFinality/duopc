import Testing
@preconcurrency import RoyalVNCKit
@testable import DuoRemote

@MainActor
struct KeyMappingTests {
    @Test func asciiAndControls() {
        #expect(KeyMapping.keyCodes(for: "aZ") == [VNCKeyCode(0x61), VNCKeyCode(0x5A)])
        #expect(KeyMapping.keyCodes(for: "\n") == [VNCKeyCode.return])
        #expect(KeyMapping.keyCodes(for: "\t") == [VNCKeyCode.tab])
    }

    @Test func latin1AndUnicode() {
        #expect(KeyMapping.keyCodes(for: "é") == [VNCKeyCode(0xE9)])
        #expect(KeyMapping.keyCodes(for: "€") == [VNCKeyCode(0x0100_20AC)])
    }

    @Test func everyLineBreakBecomesNewline() {
        #expect(KeyMapping.normalizingLineBreaks("a\r\nb\rc\nd") == "a\nb\nc\nd")
        #expect(KeyMapping.normalizingLineBreaks("a\u{2028}b\u{2029}c\u{85}d") == "a\nb\nc\nd")
        #expect(KeyMapping.normalizingLineBreaks("a\r\rb") == "a\n\nb")
        #expect(KeyMapping.normalizingLineBreaks("a\r\n\nb") == "a\n\nb")
        #expect(KeyMapping.normalizingLineBreaks("plain") == "plain")
    }

    @Test func pasteLinesDropEndBreaksAndStrayReturns() {
        #expect(KeyMapping.pasteLines("one\r\ntwo\r") == ["one", "two"])
        #expect(KeyMapping.pasteLines("\n\u{2029}x\u{2028}") == ["x"])
        #expect(KeyMapping.pasteLines("\r\n") == [])
        #expect(KeyMapping.pasteLines("a\rb").allSatisfy { !$0.contains("\r") })
    }

    @Test func confirmMultiLineOrLongPastes() {
        #expect(!KeyMapping.pasteNeedsConfirmation(KeyMapping.pasteLines("hello\n")))
        #expect(KeyMapping.pasteNeedsConfirmation(KeyMapping.pasteLines("a\rb")))
        #expect(!KeyMapping.pasteNeedsConfirmation([String(repeating: "x", count: 2_000)]))
        #expect(KeyMapping.pasteNeedsConfirmation([String(repeating: "x", count: 2_001)]))
    }
}
