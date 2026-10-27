@preconcurrency import RoyalVNCKit
import CoreGraphics
import Foundation
import IOSurface
import Observation
import UIKit
import UniformTypeIdentifiers

/// How hard the PC compresses its screen (Tight JPEG quality and zlib level). Lower quality is
/// faster on a slow link; TightVNC re-sends areas that stop changing losslessly, so still text
/// sharpens either way.
enum PictureQuality: String, CaseIterable, Identifiable {
    case fast, balanced, sharp

    var id: String { rawValue }
    static let storageKey = "pictureQuality"
    static var current: PictureQuality {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PictureQuality.init(rawValue:)) ?? .balanced
    }

    var title: String {
        switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .sharp: "Sharp" }
    }

    var jpegQuality: Int {
        switch self { case .fast: 3; case .balanced: 6; case .sharp: 8 }
    }

    /// Higher squeezes harder (less data, more PC time): worth it on a slow upload, not on Wi-Fi.
    var compressionLevel: Int {
        switch self { case .fast: 6; case .balanced: 5; case .sharp: 3 }
    }

    /// Video streaming bitrate (kbps). The PC's screen is 4K-class, so sharp text wants plenty.
    var videoBitrateKbps: Int {
        switch self { case .fast: 8_000; case .balanced: 20_000; case .sharp: 45_000 }
    }
}

/// What the canvas view implements so the session can poke it (imperative, high frequency —
/// deliberately not observation).
protocol SessionDisplay: AnyObject {
    /// A new framebuffer (connected, resized): plays the materialise effect.
    func framebufferDidChange()
    /// The next video frame, in a different surface: just show it.
    func frameDidArrive()
    func cursorDidChange()
    func viewportDidChange()
    /// Typing or clicking: draw at the full rate for a moment, so the PC's answer shows the instant it arrives.
    func markActive()
}

/// One remote PC. Long-lived: survives reconnects so the viewport and pointer stay put.
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
        /// The PC offered no sign-in at all, or a kind a Windows VNC server doesn't use.
        case insecureAuthentication
        /// The gateway's certificate isn't the paired one: another server, or the PC was set up again.
        case gatewayCertificateMismatch
        /// The gateway doesn't know this phone (unpaired with `revoke`, or the token is missing).
        case gatewayRejected
    }

    let hostname: String
    let port: UInt16

    private(set) var status: Status = .idle
    private(set) var framebufferSize: CGSize?
    /// This PC's scroll speed (from the ••• menu); nil = the global default.
    var scrollSpeedOverride: Double?
    static let defaultScrollSpeed = 3.0
    static var globalScrollSpeed: Double {
        UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? defaultScrollSpeed
    }
    var effectiveScrollSpeed: Double { scrollSpeedOverride ?? Self.globalScrollSpeed }
    var inputMode: InputMode = UserDefaults.standard.string(forKey: "defaultInputMode").flatMap(InputMode.init(rawValue:)) ?? .trackpad
    let modifiers = ModifierState()
    let isDemo: Bool

    /// The PC's cursor is the text I-beam (heuristic from its shape).
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
    /// The video stream, when this session uses it instead of VNC.
    @ObservationIgnored private var video: VideoStream?
    /// Where input goes: the video stream or VNC.
    private var link: (any RemoteLink)? { video ?? connection }
    /// Connected over video streaming rather than VNC.
    private(set) var isVideo = false
    /// A notice from the PC about the video (e.g. its screen can't be captured right now).
    private(set) var videoNotice: String?
    @ObservationIgnored private var videoStatsCount = 0
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
    ///   - allowOtherAuth: answer sign-in requests other than a Windows VNC one, or none at all.
    ///   - gateway: connect through a paired DuoPC Gateway (pinned TLS 1.3 + pairing token).
    func connect(username: String, password: String, address: String? = nil, allowOtherAuth: Bool = false,
                 gateway: VNCGatewaySettings? = nil) {
        connect(credentials: .init(username: username, password: password), address: address,
                allowOtherAuth: allowOtherAuth, gateway: gateway, log: { [weak self] line in
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
                 gateway: VNCGatewaySettings? = nil, log: (@Sendable (String) -> Void)? = nil) {
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
        connection.isUnauthenticatedAccessAllowed = allowOtherAuth   // a PC with no sign-in at all
        connection.gateway = gateway
        let quality = PictureQuality.current
        connection.jpegQualityLevel = quality.jpegQuality
        connection.compressionLevel = quality.compressionLevel
        if gateway != nil { note("direct: TLS 1.3, pinned certificate") }
        let bridge = ConnectionBridge(session: self, credentials: credentials, allowOtherAuth: allowOtherAuth,
                                      dirty: frameDirty, log: log)
        connection.delegate = bridge
        connection.clipboardDelegate = bridge
        connection.frameDelegate = bridge
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
        video?.close()
        if connection == nil && video == nil { status = .disconnected(nil) }
    }

    /// Drops the current connection at once, so the next connect can use another channel.
    func prepareToReconnect() {
        guard !isDemo else { return }
        tearDown()
        status = .idle
    }

    // MARK: Video streaming

    /// Connects over DuoPC's video channel (HEVC from the PC's GPU) instead of VNC.
    func connectVideo(gateway: VNCGatewaySettings, address: String? = nil) {
        guard !isDemo else { return }
        tearDown()
        let stream = VideoStream(host: address ?? hostname, port: port, gateway: gateway,
                                 bitrateKbps: PictureQuality.current.videoBitrateKbps, fps: 60)
        stream.onEvent = { [weak self, weak stream] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let stream else { return }
                    self.videoEvent(event, from: stream)
                }
            }
        }
        video = stream
        isVideo = true
        videoNotice = nil
        cursor = nil
        cursorIsTextBeam = false
        userDisconnecting = false
        status = .connecting
        note("video: connecting")
        stream.start()
    }

    private func videoEvent(_ event: VideoStream.Event, from stream: VideoStream) {
        guard stream === video else { return }
        switch event {
        case .frame(let box):
            let sizeChanged = framebufferSize != box.size
            surface = box
            if sizeChanged {
                let first = framebufferSize == nil
                framebufferSize = box.size
                viewport.setContentSize(box.size)
                if first || pointer.x >= box.size.width || pointer.y >= box.size.height {
                    pointer = CGPoint(x: box.size.width / 2, y: box.size.height / 2)
                }
                note("video: \(Int(box.size.width))×\(Int(box.size.height))")
            }
            if status != .connected { status = .connected }
            if videoNotice != nil { videoNotice = nil }
            frameDirty.set()
            if sizeChanged { display?.framebufferDidChange() } else { display?.frameDidArrive() }
        case .notice(let text):
            note("video: \(text)")
            videoNotice = text
        case .log(let line):
            note("video: \(line)")
        case .stats(let fps, let skipped, let kbps, let roundTripMs):
            // One line every few seconds is enough to see how the link is doing.
            videoStatsCount += 1
            if videoStatsCount % 5 == 1 {
                note("video: \(fps) fps, \(kbps / 1000) Mbps, \(skipped) skipped, round trip \(roundTripMs) ms")
            }
        case .closed(let failure):
            video = nil
            if userDisconnecting { status = .disconnected(nil); return }
            note("video: closed \(failure.map { "\($0)" } ?? "")")
            switch failure {
            case nil: status = .disconnected(nil)
            case .rejected?: status = .disconnected(.gatewayRejected)
            case .certificateMismatch?: status = .disconnected(.gatewayCertificateMismatch)
            case .unavailable?: status = .disconnected(.network("Video streaming isn't set up on this PC yet. Run Setup-DuoPC.ps1 on the PC again, or turn off Video streaming for this PC."))
            case .closed?: status = .disconnected(.closedByServer)
            case .network(let message)?: status = .disconnected(.network(message))
            }
        }
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
        video?.onEvent = nil
        video?.close()
        video = nil
        isVideo = false
        videoNotice = nil
        heldModifiers = []
        heldButton = nil
        isButtonHeld = false
        pendingMove = false
    }

    // Called by ConnectionBridge on the main actor. Callbacks from a superseded connection are dropped.

    func bridge(_ b: ConnectionBridge, didChange s: VNCConnection.Status, authFailed: Bool, authRefused: Bool,
                gatewayIssue: GatewayIssue?, message: String?) {
        guard b === bridge else { return }
        switch s {
        case .connecting: status = .connecting
        case .connected: status = .connected
        case .disconnecting: break
        case .disconnected:
            if userDisconnecting { status = .disconnected(nil) }
            else if gatewayIssue == .certificateMismatch { status = .disconnected(.gatewayCertificateMismatch) }
            else if gatewayIssue == .notPaired { status = .disconnected(.gatewayRejected) }
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
        link?.mouseMove(x: x, y: y)
    }

    func click(_ button: VNCMouseButton) {
        buttonDown(button)
        buttonUp(button)
        if button == .left, autoCompose, autoComposeArmed { checkForTextClick() }
    }

    /// After a left click, give the PC a moment to update the cursor shape; if it's the text
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
        heldModifiers.forEach { link?.keyDown($0) }
        let (x, y) = wirePointer
        link?.mouseButtonDown(button, x: x, y: y)
        heldButton = button
        isButtonHeld = true
        clickObserver?(pointer)
    }

    func buttonUp(_ button: VNCMouseButton) {
        flushPointer()
        let (x, y) = wirePointer
        link?.mouseButtonUp(button, x: x, y: y)
        heldButton = nil
        isButtonHeld = false
        heldModifiers.reversed().forEach { link?.keyUp($0) }
        heldModifiers = []
    }

    func scroll(_ wheel: VNCMouseWheel, steps: UInt32) {
        guard steps > 0 else { return }
        flushPointer()
        let (x, y) = wirePointer
        link?.mouseWheel(wheel, x: x, y: y, steps: steps)
    }

    private var wirePointer: (UInt16, UInt16) {
        (UInt16(clamping: Int(pointer.x.rounded())), UInt16(clamping: Int(pointer.y.rounded())))
    }

    private func releaseHeldInput() {
        if let heldButton { buttonUp(heldButton) }
    }

    // MARK: Keyboard

    /// Raw key events (hardware keyboard). No sticky modifiers applied.
    func keyDown(_ key: VNCKeyCode) {
        display?.markActive()
        link?.keyDown(key)
    }
    func keyUp(_ key: VNCKeyCode) { link?.keyUp(key) }

    /// Down + up, wrapped in the latched/locked modifiers.
    func press(_ key: VNCKeyCode) {
        display?.markActive()
        withModifiers { $0.tap(key) }
    }

    /// Types text, wrapped in the latched/locked modifiers. \n → Return, \t → Tab.
    func type(_ text: String) {
        let codes = KeyMapping.keyCodes(for: text)
        guard !codes.isEmpty else { return }
        display?.markActive()
        withModifiers { c in codes.forEach(c.tap) }
    }

    /// Holds the shortcut's keys together, then releases them. The sticky modifiers stay as they are.
    func send(_ shortcut: WindowsShortcut) {
        guard let c = link else { return }
        note("shortcut: \(shortcut.title)")
        shortcut.keys.forEach { c.keyDown($0) }
        shortcut.keys.reversed().forEach { c.keyUp($0) }
    }

    private func withModifiers(_ body: (any RemoteLink) -> Void) {
        let mods = modifiers.consume()
        guard let c = link else { return }
        mods.forEach { c.keyDown($0) }
        body(c)
        mods.reversed().forEach { c.keyUp($0) }
    }

    // MARK: Clipboard

    /// iPhone → PC: types `text` into whatever has focus on the PC — the same path as the
    /// compose box. Typing rather than ClientCutText, because that is Latin-1 only and would mangle
    /// anything else.
    func pasteToPC(_ text: String) {
        // Never submit: drop trailing line breaks, and type inner ones as Shift-Return (a soft
        // line break in chat and web apps, an ordinary newline in editors).
        let lines = KeyMapping.pasteLines(text)
        guard !lines.isEmpty, let c = link else {
            note("paste to PC: nothing sent\(link == nil ? " — not connected" : "")")
            return
        }
        note("paste to PC: typing \(lines.reduce(0) { $0 + $1.count }) chars")
        for (i, line) in lines.enumerated() {
            KeyMapping.keyCodes(for: line).forEach(c.tap)
            if i < lines.count - 1 {
                c.keyDown(.shift); c.tap(.return); c.keyUp(.shift)
            }
        }
    }

    /// Types text without applying the sticky modifiers (compose box).
    func typeRaw(_ text: String) {
        guard let c = link else { return }
        KeyMapping.keyCodes(for: text).forEach(c.tap)
    }

    // MARK: Snapshot

    /// The part of the PC's screen currently visible on the canvas, as an image (for Live Text).
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

    /// Asks the PC for a fresh keyframe (••• → Refresh picture), in case the picture is stuck.
    func refreshVideo() {
        guard let video else { return }
        note("video: refresh requested")
        video.requestKeyframe()
    }

    // MARK: Picture quality

    /// Applies straight away (no reconnect) and becomes the default for new connections.
    func applyPictureQuality(_ quality: PictureQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: PictureQuality.storageKey)
        connection?.updateQuality(jpegQuality: quality.jpegQuality, compressionLevel: quality.compressionLevel)
        video?.setBitrate(kbps: quality.videoBitrateKbps)
        note("picture quality: \(quality.rawValue)")
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

