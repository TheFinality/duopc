@preconcurrency import RoyalVNCKit
import SwiftUI
import UIKit

/// Zero-size first responder: hardware key presses always, the software keyboard when shown.
struct KeyboardInput: UIViewRepresentable {
    let session: VNCSession
    @Binding var softwareKeyboardShown: Bool

    /// While true (e.g. the compose box has focus) this view gives up first responder.
    var isSuspended = false

    init(session: VNCSession, softwareKeyboardShown: Binding<Bool>, isSuspended: Bool = false) {
        self.session = session
        self._softwareKeyboardShown = softwareKeyboardShown
        self.isSuspended = isSuspended
    }

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView(frame: .zero)
        view.session = session
        view.shownBinding = $softwareKeyboardShown
        view.softwareKeyboardShown = softwareKeyboardShown
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.session = session
        view.shownBinding = $softwareKeyboardShown
        view.softwareKeyboardShown = softwareKeyboardShown
        view.isSuspended = isSuspended
        view.claimFirstResponder()
    }
}

final class KeyCaptureView: UIView, UIKeyInput, UITextInputTraits {
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
    private var lastShownAt: TimeInterval = 0
    private var held: [UInt32: VNCKeyCode] = [:]

    // MARK: UITextInputTraits
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
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

    var hasText: Bool { true }

    func insertText(_ text: String) {
        session?.type(text)
    }

    func deleteBackward() {
        session?.press(.delete)
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
