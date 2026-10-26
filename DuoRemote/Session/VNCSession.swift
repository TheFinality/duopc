@preconcurrency import RoyalVNCKit
import CoreGraphics
import Foundation
import IOSurface
import Observation
import UIKit
import UniformTypeIdentifiers

/// What the canvas view implements so the session can poke it (imperative, high frequency —
/// deliberately not observation).
protocol SessionDisplay: AnyObject {
    func framebufferDidChange()
    func cursorDidChange()
    func viewportDidChange()
}

/// One remote Mac. Long-lived: survives reconnects so the viewport and pointer stay put.
@Observable
final class VNCSession {
    enum Status: Equatable {
        case idle, connecting, connected
        case disconnected(Failure?)          // nil = disconnected by the user
    }

    enum Failure: Equatable {
        case authenticationFailed
        case network(String)
        case closedByServer
        /// Not reached through Tailscale, so the saved password wasn't sent.
        case outsideTailscale
        /// The Mac asked for a plain VNC password rather than a macOS sign-in.
        case insecureAuthentication
    }

    let hostname: String
    let port: UInt16

    private(set) var status: Status = .idle
    private(set) var framebufferSize: CGSize?
    /// This Mac's scroll speed (from the ••• menu); nil = the global default.
    var scrollSpeedOverride: Double?
    static let defaultScrollSpeed = 3.0
    static var globalScrollSpeed: Double {
        UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? defaultScrollSpeed
    }
    var effectiveScrollSpeed: Double { scrollSpeedOverride ?? Self.globalScrollSpeed }
    var inputMode: InputMode = UserDefaults.standard.string(forKey: "defaultInputMode").flatMap(InputMode.init(rawValue:)) ?? .trackpad
    let modifiers = ModifierState()
    let isDemo: Bool

    /// The Mac's cursor is the text I-beam (heuristic from its shape).
    private(set) var cursorIsTextBeam = false
    /// Bumped when the user clicks into text (I-beam) — the shell opens the compose box.
    private(set) var composeRequests = 0
    /// Open the compose box automatically on a click into text. Read live, so the Settings
    /// switch applies to a session that's already open.
    var autoCompose: Bool { UserDefaults.standard.object(forKey: "autoCompose") as? Bool ?? true }
    /// Off once the user closes the compose box, until the pointer leaves text: in a document
    /// the whole window is an I-beam, and every click would otherwise reopen it.
    @ObservationIgnored private var autoComposeArmed = true
    /// Clipboard text waiting for the user to confirm before it's typed (multi-line or long).
    var pendingPaste: String?
    /// Recent connection events (state, auth, framebuffer, clipboard) for the diagnostics sheet.
    private(set) var eventLog: [String] = []

    // MARK: Canvas state (not observed — read by the canvas every frame)

    @ObservationIgnored var viewport = Viewport()
    /// Pointer position in framebuffer pixels.
    @ObservationIgnored private(set) var pointer: CGPoint = .zero
    @ObservationIgnored private(set) var surface: SurfaceBox?
    @ObservationIgnored private(set) var cursor: CursorBox?
    @ObservationIgnored let frameDirty = DirtyFlag()
    @ObservationIgnored weak var display: SessionDisplay?
    /// Called with the pointer (framebuffer pixels) on every click or button press — the canvas
    /// uses it for click ripples, whichever surface the click came from.
    @ObservationIgnored var clickObserver: ((CGPoint) -> Void)?
    /// A mouse button is held (dragging) — the canvas shows its precision loupe.
    @ObservationIgnored private(set) var isButtonHeld = false

    @ObservationIgnored private var connection: VNCConnection?
    @ObservationIgnored private var bridge: ConnectionBridge?
    @ObservationIgnored private var userDisconnecting = false
    @ObservationIgnored private var pendingMove = false
    @ObservationIgnored private var heldModifiers: [VNCKeyCode] = []
    @ObservationIgnored private var heldButton: VNCMouseButton?
    @ObservationIgnored private var log: (@Sendable (String) -> Void)?

    init(hostname: String, port: UInt16 = 5900) {
        self.hostname = hostname
        self.port = port
        self.isDemo = false
    }

    private init(demo: Void) {
        hostname = "demo"
        port = 0
        isDemo = true
        if let box = DemoFramebuffer.make() {
            surface = box
            framebufferSize = box.size
            viewport.setContentSize(box.size)
            pointer = CGPoint(x: box.size.width / 2, y: box.size.height / 2)
        }
        status = .connected
    }

    /// A session on a generated test pattern, no network. For layout checks and screenshots.
    static func demo() -> VNCSession { VNCSession(demo: ()) }

    // MARK: Connection

    /// - Parameters:
    ///   - address: the already-checked address to connect to, instead of resolving `hostname` again.
    ///   - allowOtherAuth: answer sign-in requests other than a macOS one.
    func connect(username: String, password: String, address: String? = nil, allowOtherAuth: Bool = false) {
        connect(credentials: .init(username: username, password: password), address: address,
                allowOtherAuth: allowOtherAuth, log: { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.note(line) } }
        })
    }

    func note(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        eventLog.append("\(stamp)  \(line)")
        if eventLog.count > 200 { eventLog.removeFirst(eventLog.count - 200) }
    }

    /// `credentials == nil` → the auth request is answered with nothing (smoke test).
    func connect(credentials: ConnectionBridge.Credentials?, address: String? = nil, allowOtherAuth: Bool = false,
                 log: (@Sendable (String) -> Void)? = nil) {
        guard !isDemo else { return }
        tearDown()
        self.log = log
        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
                                              hostname: address ?? hostname,
                                              port: port,
                                              isShared: true,
                                              isScalingEnabled: false,
                                              useDisplayLink: false,
                                              inputMode: .forwardAllKeyboardShortcutsAndHotKeys,
                                              isClipboardRedirectionEnabled: false,
                                              colorDepth: .depth24Bit,
                                              frameEncodings: .default)
        let connection = VNCConnection(settings: settings)
        connection.isUnauthenticatedAccessAllowed = allowOtherAuth   // a Mac with no sign-in at all
        let bridge = ConnectionBridge(session: self, credentials: credentials, allowOtherAuth: allowOtherAuth,
                                      dirty: frameDirty, log: log)
        connection.delegate = bridge
        connection.clipboardDelegate = bridge
        self.connection = connection
        self.bridge = bridge
        userDisconnecting = false
        status = .connecting
        connection.connect()
    }

    func disconnect() {
        guard !isDemo else { return }
        userDisconnecting = true
        releaseHeldInput()
        connection?.disconnect()
        if connection == nil { status = .disconnected(nil) }
    }

    /// Shows `failure` without connecting (e.g. the password would leave Tailscale).
    func block(_ failure: Failure) {
        guard !isDemo else { return }
        tearDown()
        status = .disconnected(failure)
    }

    private func tearDown() {
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
        bridge = nil
        heldModifiers = []
        heldButton = nil
        isButtonHeld = false
        pendingMove = false
    }

    // Called by ConnectionBridge on the main actor. Callbacks from a superseded connection are dropped.

    func bridge(_ b: ConnectionBridge, didChange s: VNCConnection.Status, authFailed: Bool, authRefused: Bool, message: String?) {
        guard b === bridge else { return }
        switch s {
        case .connecting: status = .connecting
        case .connected: status = .connected
        case .disconnecting: break
        case .disconnected:
            if userDisconnecting { status = .disconnected(nil) }
            else if authRefused { status = .disconnected(.insecureAuthentication) }
            else if authFailed { status = .disconnected(.authenticationFailed) }
            else if let message { status = .disconnected(.network(message)) }
            else { status = .disconnected(.closedByServer) }
            connection?.delegate = nil
            connection = nil
            bridge = nil
        }
    }

    func bridge(_ b: ConnectionBridge, didSetFramebuffer box: SurfaceBox) {
        guard b === bridge else { return }
        let firstFrame = surface == nil
        surface = box
        framebufferSize = box.size
        viewport.setContentSize(box.size)
        if firstFrame || pointer.x >= box.size.width || pointer.y >= box.size.height {
            pointer = CGPoint(x: box.size.width / 2, y: box.size.height / 2)
        }
        display?.framebufferDidChange()
    }

    func bridge(_ b: ConnectionBridge, didReceiveClipboard text: String) {
        guard b === bridge else { return }
        guard !text.isEmpty else { return }
        UIPasteboard.general.setShortLivedText(text)
    }

    func bridge(_ b: ConnectionBridge, didUpdateCursor box: CursorBox) {
        guard b === bridge else { return }
        cursor = box
        cursorIsTextBeam = Self.looksLikeTextBeam(box)
        if !cursorIsTextBeam { autoComposeArmed = true }
        display?.cursorDidChange()
    }

    // MARK: Pointer (framebuffer pixels)

    /// Moves the local pointer; the move is sent on the next `flushPointer()` (once per frame).
    func movePointer(to p: CGPoint) {
        pointer = viewport.clampToContent(p)
        pendingMove = true
    }

    func flushPointer() {
        guard pendingMove else { return }
        pendingMove = false
        let (x, y) = wirePointer
        connection?.mouseMove(x: x, y: y)
    }

    func click(_ button: VNCMouseButton) {
        buttonDown(button)
        buttonUp(button)
        if button == .left, autoCompose, autoComposeArmed { checkForTextClick() }
    }

    /// After a left click, give the Mac a moment to update the cursor shape; if it's the text
    /// I-beam, the click was (very likely) into text → ask the shell for the compose box.
    /// The user closed the compose box: don't reopen it until the pointer has left text.
    func composeDismissed() { autoComposeArmed = false }

    private func checkForTextClick() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.status == .connected, self.cursorIsTextBeam, self.autoComposeArmed else { return }
            self.composeRequests += 1
        }
    }

    /// I-beam: taller than wide, hotspot near the middle. (Arrows have a top-left hotspot;
    /// crosshairs/move cursors are square.)
    static func looksLikeTextBeam(_ c: CursorBox) -> Bool {
        guard !c.hidden, let img = c.image else { return false }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        guard w > 0, h > 0, w < h * 0.7 else { return false }
        let fx = c.hotspot.x / w, fy = c.hotspot.y / h
        return (0.25...0.75).contains(fx) && (0.3...0.7).contains(fy)
    }

    /// Presses a mouse button with the latched/locked modifiers held until `buttonUp`.
    func buttonDown(_ button: VNCMouseButton) {
        flushPointer()
        heldModifiers = modifiers.consume()
        heldModifiers.forEach { connection?.keyDown($0) }
        let (x, y) = wirePointer
        connection?.mouseButtonDown(button, x: x, y: y)
        heldButton = button
        isButtonHeld = true
        clickObserver?(pointer)
    }

    func buttonUp(_ button: VNCMouseButton) {
        flushPointer()
        let (x, y) = wirePointer
        connection?.mouseButtonUp(button, x: x, y: y)
        heldButton = nil
        isButtonHeld = false
        heldModifiers.reversed().forEach { connection?.keyUp($0) }
        heldModifiers = []
    }

    func scroll(_ wheel: VNCMouseWheel, steps: UInt32) {
        guard steps > 0 else { return }
        flushPointer()
        let (x, y) = wirePointer
        connection?.mouseWheel(wheel, x: x, y: y, steps: steps)
    }

    private var wirePointer: (UInt16, UInt16) {
        (UInt16(clamping: Int(pointer.x.rounded())), UInt16(clamping: Int(pointer.y.rounded())))
    }

    private func releaseHeldInput() {
        if let heldButton { buttonUp(heldButton) }
    }

    // MARK: Keyboard

    /// Raw key events (hardware keyboard). No sticky modifiers applied.
    func keyDown(_ key: VNCKeyCode) { connection?.keyDown(key) }
    func keyUp(_ key: VNCKeyCode) { connection?.keyUp(key) }

    /// Down + up, wrapped in the latched/locked modifiers.
    func press(_ key: VNCKeyCode) {
        withModifiers { $0.tap(key) }
    }

    /// Types text, wrapped in the latched/locked modifiers. \n → Return, \t → Tab.
    func type(_ text: String) {
        let codes = KeyMapping.keyCodes(for: text)
        guard !codes.isEmpty else { return }
        withModifiers { c in codes.forEach(c.tap) }
    }

    private func withModifiers(_ body: (VNCConnection) -> Void) {
        let mods = modifiers.consume()
        guard let c = connection else { return }
        mods.forEach { c.keyDown($0) }
        body(c)
        mods.reversed().forEach { c.keyUp($0) }
    }

    // MARK: Clipboard

    /// iPhone → Mac: types `text` into whatever has focus on the Mac — the same path as the
    /// compose box. (No clipboard message: macOS Screen Sharing ignores ClientCutText from
    /// non-Apple clients and can then swallow the keystrokes that follow.)
    func pasteToMac(_ text: String) {
        // Never submit: drop trailing line breaks, and type inner ones as Shift-Return (a soft
        // line break in chat and web apps, an ordinary newline in editors).
        let lines = KeyMapping.pasteLines(text)
        guard !lines.isEmpty, let c = connection else {
            note("paste to Mac: nothing sent\(connection == nil ? " — not connected" : "")")
            return
        }
        note("paste to Mac: typing \(lines.reduce(0) { $0 + $1.count }) chars")
        for (i, line) in lines.enumerated() {
            KeyMapping.keyCodes(for: line).forEach(c.tap)
            if i < lines.count - 1 {
                c.keyDown(.shift); c.tap(.return); c.keyUp(.shift)
            }
        }
    }

    /// Types text without applying the sticky modifiers (compose box).
    func typeRaw(_ text: String) {
        guard let c = connection else { return }
        KeyMapping.keyCodes(for: text).forEach(c.tap)
    }

    // MARK: Snapshot

    /// The part of the Mac's screen currently visible on the canvas, as an image (for Live Text).
    func visibleSnapshot() -> UIImage? {
        guard let box = surface else { return nil }
        let surf = box.surface
        let vp = viewport, visible = vp.visibleRect
        let a = vp.clampToContent(vp.toContent(CGPoint(x: visible.minX, y: visible.minY)))
        let b = vp.clampToContent(vp.toContent(CGPoint(x: visible.maxX, y: visible.maxY)))
        var crop = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).integral
        if crop.width <= 8 || crop.height <= 8 { crop = CGRect(x: 0, y: 0, width: surf.width, height: surf.height) }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        surf.lock(options: .readOnly, seed: nil)
        defer { surf.unlock(options: .readOnly, seed: nil) }
        // Copy into memory we own while the surface is locked; an image that only wraps the
        // surface would keep reading it after the decoder rewrites or frees it.
        guard let wrapped = CGContext(data: surf.baseAddress, width: surf.width, height: surf.height,
                                      bitsPerComponent: 8, bytesPerRow: surf.bytesPerRow, space: space, bitmapInfo: info)?.makeImage(),
              let copy = CGContext(data: nil, width: Int(crop.width), height: Int(crop.height),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        copy.draw(wrapped, in: CGRect(x: -crop.minX, y: crop.maxY - CGFloat(surf.height),
                                      width: CGFloat(surf.width), height: CGFloat(surf.height)))
        return copy.makeImage().map { UIImage(cgImage: $0) }
    }

    // MARK: View commands

    func zoomToFit() {
        viewport.zoomToFit()
        display?.viewportDidChange()
    }

    func zoomToActualPixels() {
        viewport.zoomToActualPixels(around: pointer)
        display?.viewportDidChange()
    }
}

extension UIPasteboard {
    /// Writing never prompts (reading would). Local-only and short-lived: no Handoff, and it expires.
    func setShortLivedText(_ text: String) {
        setItems([[UTType.utf8PlainText.identifier: text]],
                 options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(600)])
    }
}

private extension VNCConnection {
    func tap(_ key: VNCKeyCode) {
        keyDown(key)
        keyUp(key)
    }
}
