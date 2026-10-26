@preconcurrency import RoyalVNCKit
import SwiftUI
import UIKit

/// Zero-size first responder: hardware key presses always, the software keyboard when shown.
struct KeyboardInput: UIViewRepresentable {
    let session: VNCSession
    @Binding var softwareKeyboardShown: Bool

    /// While true (e.g. the compose box has focus) this view gives up first responder.
    var isSuspended = false
    /// Autocorrect and the suggestion bar, if Settings allows them (off in laptop pose: no room).
    var allowsSuggestions = true

    init(session: VNCSession, softwareKeyboardShown: Binding<Bool>, isSuspended: Bool = false, allowsSuggestions: Bool = true) {
        self.session = session
        self._softwareKeyboardShown = softwareKeyboardShown
        self.isSuspended = isSuspended
        self.allowsSuggestions = allowsSuggestions
    }

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView(frame: .zero)
        view.session = session
        session.onCaretMoved = { [weak view] in view?.forgetTyped() }
        view.shownBinding = $softwareKeyboardShown
        view.softwareKeyboardShown = softwareKeyboardShown
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        if view.session !== session { session.onCaretMoved = { [weak view] in view?.forgetTyped() } }
        view.session = session
        view.shownBinding = $softwareKeyboardShown
        view.softwareKeyboardShown = softwareKeyboardShown
        view.isSuspended = isSuspended
        view.allowsSuggestions = allowsSuggestions
        view.claimFirstResponder()
    }
}

/// The on-screen keyboard's target. It's a full text input over `typed`, a mirror of what's been typed
/// on the PC since its text cursor last moved some other way, so iOS can autocorrect, spellcheck
/// and suggest words. Edits to that text become keystrokes: a correction is Backspaces plus the new
/// word, and moving the cursor (the space bar drag) is arrow keys. Anything else that might move the
/// PC's cursor (a click, a key from the bar, a shortcut) clears the mirror.
final class KeyCaptureView: UIView, UITextInput {
    var session: VNCSession?
    var shownBinding: Binding<Bool>?

    var softwareKeyboardShown = false {
        didSet {
            guard softwareKeyboardShown != oldValue else { return }
            if softwareKeyboardShown { lastShownAt = ProcessInfo.processInfo.systemUptime }
            if isFirstResponder { reloadInputViews() }
        }
    }

    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended { if isFirstResponder { _ = resignFirstResponder() } }
            else { DispatchQueue.main.async { [weak self] in self?.claimFirstResponder() } }
        }
    }

    private let emptyInputView = UIView(frame: .zero)
    private let keyHaptic = UIImpactFeedbackGenerator(style: .light)
    /// Read live, so the Settings switch applies to an open session.
    private var keyHapticsEnabled: Bool { UserDefaults.standard.object(forKey: "keyHaptics") as? Bool ?? true }
    private var lastShownAt: TimeInterval = 0
    private var held: [UInt32: VNCKeyCode] = [:]

    // MARK: UITextInputTraits
    /// Off in laptop pose (unless Settings says otherwise); changing it swaps the keyboard in place.
    var allowsSuggestions = true {
        didSet {
            guard allowsSuggestions != oldValue, isFirstResponder else { return }
            reloadInputViews()
        }
    }
    /// Read when the keyboard comes up, so the Settings switch applies from the next time it opens.
    private var autocorrects: Bool {
        allowsSuggestions && (UserDefaults.standard.object(forKey: "keyboardAutocorrect") as? Bool ?? true)
    }
    var autocorrectionType: UITextAutocorrectionType {
        get { autocorrects ? .yes : .no }
        set {}
    }
    var spellCheckingType: UITextSpellCheckingType {
        get { autocorrects ? .yes : .no }
        set {}
    }
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var keyboardType: UIKeyboardType = .asciiCapable

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appBecameActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: First responder

    override var canBecomeFirstResponder: Bool { true }

    override var inputView: UIView? { softwareKeyboardShown ? nil : emptyInputView }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Defer: the view may not be fully in the hierarchy yet.
            DispatchQueue.main.async { [weak self] in self?.claimFirstResponder() }
        } else {
            releaseHeldKeys()
        }
    }

    func claimFirstResponder() {
        guard window != nil, !isFirstResponder, !isSuspended else { return }
        becomeFirstResponder()
    }

    @objc private func appBecameActive() { claimFirstResponder() }

    @objc private func keyboardWillHide() {
        guard softwareKeyboardShown, isFirstResponder else { return }
        // Ignore the hide that can accompany our own inputView swap.
        guard ProcessInfo.processInfo.systemUptime - lastShownAt > 0.5 else { return }
        softwareKeyboardShown = false
        shownBinding?.wrappedValue = false
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldKeys()
        return super.resignFirstResponder()
    }

    // MARK: UIKeyInput

    /// Always true, so Backspace reaches the PC even when nothing has been typed here.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        tapHaptic()
        guard let session else { return }
        marked = nil
        guard session.keyboardType(text) else { return forgetTyped() }   // a shortcut, not text
        if text.contains(where: \.isNewline) { return forgetTyped() }   // Return: a new context
        typed.insert(contentsOf: text, at: index(caret))
        caret += text.utf16.count
    }

    func deleteBackward() {
        tapHaptic()
        session?.keyboardTap(.delete)
        marked = nil
        guard caret > 0 else { return }
        let end = index(caret)
        let start = typed.index(before: end)
        caret -= typed[start..<end].utf16.count
        typed.removeSubrange(start..<end)
    }

    // MARK: Autocorrect: the typed mirror

    private var typed = ""
    /// The caret, in UTF-16 offsets into `typed` (UIKit's text positions).
    private var caret = 0
    private var marked: NSRange?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    private var length: Int { typed.utf16.count }

    private func index(_ offset: Int) -> String.Index {
        let clamped = max(0, min(offset, length))
        return String.Index(utf16Offset: clamped, in: typed)
    }

    /// Characters (what Backspace and the arrow keys move by) between two UTF-16 offsets.
    private func characters(from a: Int, to b: Int) -> Int {
        typed[index(min(a, b))..<index(max(a, b))].count
    }

    /// Clears the mirror, telling the keyboard (it's a change it didn't make).
    func forgetTyped() {
        guard !typed.isEmpty || marked != nil || caret != 0 else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        typed = ""
        caret = 0
        marked = nil
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    /// Moves the PC's cursor (arrow keys) to `offset` in the mirror.
    private func moveCaret(to offset: Int) {
        let target = max(0, min(offset, length))
        guard target != caret else { return }
        let steps = characters(from: caret, to: target)
        session?.keyboardTap(target < caret ? .leftArrow : .rightArrow, count: steps)
        caret = target
    }

    /// Replaces UTF-16 `start..<end` of the mirror with `text`, on the PC: move to `end`, Backspace
    /// back to `start`, type `text`.
    private func replaceOnPC(start: Int, end: Int, with text: String) {
        let s = max(0, min(start, length)), e = max(s, min(end, length))
        moveCaret(to: e)
        session?.keyboardTap(.delete, count: characters(from: s, to: e))
        if !text.isEmpty { session?.keyboardTypeRaw(text) }
        typed.replaceSubrange(index(s)..<index(e), with: text)
        caret = s + text.utf16.count
    }

    // MARK: UITextInput

    func text(in range: UITextRange) -> String? {
        guard let range = range as? CaretRange else { return nil }
        return String(typed[index(range.lower)..<index(range.upper)])
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? CaretRange else { return }
        replaceOnPC(start: range.lower, end: range.upper, with: text)
    }

    var selectedTextRange: UITextRange? {
        get { CaretRange(caret, caret) }
        set {
            // The PC has no selection to mirror; a moved cursor becomes arrow keys.
            guard let range = newValue as? CaretRange else { return }
            moveCaret(to: range.upper)
        }
    }

    var markedTextRange: UITextRange? {
        marked.map { CaretRange($0.location, $0.location + $0.length) }
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let text = markedText ?? ""
        let range = marked ?? NSRange(location: caret, length: 0)
        replaceOnPC(start: range.location, end: range.location + range.length, with: text)
        marked = text.isEmpty ? nil : NSRange(location: range.location, length: text.utf16.count)
    }

    func unmarkText() { marked = nil }

    var beginningOfDocument: UITextPosition { CaretPosition(0) }
    var endOfDocument: UITextPosition { CaretPosition(length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = fromPosition as? CaretPosition, let b = toPosition as? CaretPosition else { return nil }
        return CaretRange(a.offset, b.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? CaretPosition else { return nil }
        let target = p.offset + offset
        return (0...length).contains(target) ? CaretPosition(target) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? CaretPosition)?.offset ?? 0, b = (other as? CaretPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? CaretPosition)?.offset ?? 0) - ((from as? CaretPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? CaretPosition else { return nil }
        return direction == .left || direction == .up ? CaretRange(0, p.offset) : CaretRange(p.offset, length)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    func firstRect(for range: UITextRange) -> CGRect { .zero }
    func caretRect(for position: UITextPosition) -> CGRect { .zero }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    /// A light tap per on-screen key, like a real key's click. Hardware keyboards don't need one.
    private func tapHaptic() {
        guard softwareKeyboardShown, keyHapticsEnabled else { return }
        keyHaptic.impactOccurred(intensity: 0.6)
        keyHaptic.prepare()
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forgetTyped()
        var unhandled = Set<UIPress>()
        for press in presses {
            if let usage = press.key?.keyCode, let code = HIDKeyMap.key(for: usage) {
                // Release a stuck duplicate before re-pressing.
                if held[UInt32(usage.rawValue)] != nil { session?.keyUp(code) }
                held[UInt32(usage.rawValue)] = code
                session?.keyDown(code)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, event: event, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, event: event, cancelled: true)
    }

    private func release(_ presses: Set<UIPress>, event: UIPressesEvent?, cancelled: Bool) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let usage = press.key?.keyCode, let code = held.removeValue(forKey: UInt32(usage.rawValue)) {
                session?.keyUp(code)
            } else if let usage = press.key?.keyCode, let code = HIDKeyMap.key(for: usage) {
                session?.keyUp(code)
            } else {
                unhandled.insert(press)
            }
        }
        guard !unhandled.isEmpty else { return }
        if cancelled {
            super.pressesCancelled(unhandled, with: event)
        } else {
            super.pressesEnded(unhandled, with: event)
        }
    }

    private func releaseHeldKeys() {
        for code in held.values { session?.keyUp(code) }
        held.removeAll()
    }
}

/// A position in KeyCaptureView's typed mirror (UTF-16 offset).
private final class CaretPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

private final class CaretRange: UITextRange {
    let lower: Int
    let upper: Int
    init(_ a: Int, _ b: Int) { lower = min(a, b); upper = max(a, b) }
    override var start: UITextPosition { CaretPosition(lower) }
    override var end: UITextPosition { CaretPosition(upper) }
    override var isEmpty: Bool { lower == upper }
}
