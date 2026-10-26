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

    @Test func windowsShortcutsHoldWindowsKeys() {
        #expect(WindowsShortcut.ctrlAltDel.keys == [VNCKeyCode.control, VNCKeyCode.option, VNCKeyCode.forwardDelete])
        #expect(WindowsShortcut.taskManager.keys == [VNCKeyCode.control, VNCKeyCode.shift, VNCKeyCode.escape])
        #expect(WindowsShortcut.showDesktop.keys == [VNCKeyCode.command, VNCKeyCode(asciiCharacter: UInt8(ascii: "d"))])
        #expect(WindowsShortcut.allCases.allSatisfy { !$0.keys.isEmpty })
    }

    @Test func pictureQualityOrdersSharpness() {
        #expect(PictureQuality.fast.jpegQuality < PictureQuality.balanced.jpegQuality)
        #expect(PictureQuality.balanced.jpegQuality < PictureQuality.sharp.jpegQuality)
        #expect(PictureQuality.allCases.allSatisfy { (0...9).contains($0.jpegQuality) && (0...9).contains($0.compressionLevel) })
        // Balanced is what the library asked for before this was adjustable.
        #expect(PictureQuality.balanced.jpegQuality == 6 && PictureQuality.balanced.compressionLevel == 5)
    }

    // MARK: Keyboard autocorrect mirror (KeyCaptureView)

    private func keyboard() -> (KeyCaptureView, VNCSession) {
        let session = VNCSession.demo()
        let view = KeyCaptureView(frame: .zero)
        view.session = session
        session.onCaretMoved = { [weak view] in view?.forgetTyped() }
        return (view, session)
    }

    private func everything(_ view: KeyCaptureView) -> String? {
        view.textRange(from: view.beginningOfDocument, to: view.endOfDocument).flatMap { view.text(in: $0) }
    }

    @Test func correctionsEditTheTypedText() throws {
        let (view, _) = keyboard()
        view.insertText("teh")
        #expect(everything(view) == "teh")
        let word = try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        view.replace(word, withText: "the")                 // what autocorrect does
        view.insertText(" ")
        #expect(everything(view) == "the ")
        view.deleteBackward()
        #expect(everything(view) == "the")
        #expect(view.offset(from: view.beginningOfDocument, to: try #require(view.selectedTextRange).end) == 3)
    }

    @Test func movingTheCursorAndOtherInputForget() throws {
        let (view, session) = keyboard()
        view.insertText("hello")
        let start = try #require(view.position(from: view.beginningOfDocument, offset: 1))
        view.selectedTextRange = view.textRange(from: start, to: start)   // the space-bar drag
        view.insertText("X")
        #expect(everything(view) == "hXello")
        session.press(.escape)                               // a key from the bar: the PC's cursor may have moved
        #expect(everything(view) == "")
        view.insertText("a\n")                               // Return starts a new context too
        #expect(everything(view) == "")
    }
}

