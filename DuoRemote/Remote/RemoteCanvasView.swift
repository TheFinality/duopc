@preconcurrency import RoyalVNCKit
import UIKit
import QuartzCore

/// The remote screen view: Metal-rendered framebuffer, a local cursor layer, raw touch handling.
/// Runs a display link while in a window; renders only when the framebuffer, viewport or cursor
/// changed.
final class RemoteCanvasView: UIView, SessionDisplay {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private(set) var session: VNCSession
    private let renderer = FramebufferRenderer()
    private(set) var input: InputController
    private var interpreter = TouchInterpreter()
    private let cursorLayer = CALayer()
    private var updateLink: UIUpdateLink?
    private var linkProxy: DisplayLinkProxy?   // UIUpdateLink holds its target weakly
    private var lastTick: CFTimeInterval = 0
    private var lastActivity: CFTimeInterval = 0
    private var lastScreenChange: CFTimeInterval = 0
    private var needsRender = true
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private let grabHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let clickHaptic = UIImpactFeedbackGenerator(style: .light)

    var inputModeOverride: InputMode?
    /// The mouse button a pointer click is holding (see PointerInput.swift).
    var pointerButton: VNCMouseButton?

    // MARK: Effects state (see FramebufferRenderer's shader)
    private struct Ripple { var point: CGPoint; var start: CFTimeInterval; var strength: Float }
    private var ripples: [Ripple] = []
    private var materialiseStart: CFTimeInterval?
    private var frost: Float = 0
    private var wasConnected = false
    private var wasConnectedOnce = false
    private var heldSince: CFTimeInterval?
    private var loupeAmount: Float = 0
    #if DEBUG
    /// Screenshot aids: freeze an effect mid-way (`-fxFrost`, `-fxLoupe`, `-fxMaterialise`, `-fxRipple`).
    private static let fxPreview = Set(ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("-fx") })
    #else
    private static let fxPreview: Set<String> = []
    #endif

    var obscuredInsets: UIEdgeInsets = .zero {
        didSet { if obscuredInsets != oldValue { setNeedsLayout() } }
    }

    init(session: VNCSession) {
        self.session = session
        self.input = InputController(session: session)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        installPointerInput()
        backgroundColor = .black
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer.addSublayer(cursorLayer)
        attach(session)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Swaps in another session (SwiftUI may reuse the view).
    func attach(_ s: VNCSession) {
        if s !== session {
            session.display = nil
            session = s
            input = InputController(session: s)
            interpreter = TouchInterpreter()
        }
        if s.display !== self {
            s.display = self
            setNeedsLayout()
        }
        input.onGrab = { [weak self] in self?.grabHaptic.impactOccurred() }
        input.onClick = { [weak self] in self?.clickHaptic.impactOccurred(intensity: 0.5) }
        s.clickObserver = { [weak self] p in self?.addRipple(atContentPoint: p) }
        if s.surface != nil, materialiseStart == nil, !wasConnected { startMaterialise() }
        renderer?.setSurface(s.surface)
        updateCursorImage()
        setNeedsLayout()
        needsRender = true
    }

    // MARK: Layout + display link

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // The viewport is the session's. While a layout change swaps canvases (e.g. into laptop
        // pose) two can exist for a moment — only the current one may set its bounds. A canvas
        // that's on screen reclaims the viewport if whoever held it has gone.
        if session.display == nil, window != nil { session.display = self }
        guard session.display === self else { return }
        session.viewport.setBounds(bounds.size, insets: obscuredInsets, displayScale: scale)
        // Never draw from layout: a fold or rotation lays out many times in a row, and each draw
        // can block waiting for a drawable. The display link draws once per frame instead.
        needsRender = true
        lastActivity = CACurrentMediaTime()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if updateLink == nil {
            // UIUpdateLink follows the view's window and screen (a CADisplayLink stays on the
            // display it was made for — wrong after a fold moves the app to the other screen).
            let proxy = DisplayLinkProxy(self)
            linkProxy = proxy
            let link = UIUpdateLink(view: self, actionTarget: proxy,
                                    selector: #selector(DisplayLinkProxy.update(_:info:)))
            link.requiresContinuousUpdates = true
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            updateLink = link
        }
        updateLink?.isEnabled = window != nil
        if window == nil, session.display === self { session.display = nil }
    }

    fileprivate func tick(_ link: UIUpdateLink, _ info: UIUpdateInfo) {
        if session.display == nil, window != nil {
            session.display = self
            setNeedsLayout()
        }
        // Mid-fold the scene is briefly not foreground-active: don't draw then.
        guard let scene = window?.windowScene, scene.activationState != .background else { return }
        let now = info.modelTime
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 0.1)
        lastTick = now

        input.handle(interpreter.tick(time: CACurrentMediaTime()))
        if input.isAnimating {
            input.tick(dt: CGFloat(dt))
            needsRender = true
            lastActivity = now
        }
        session.flushPointer()

        if session.frameDirty.testAndClear() {
            needsRender = true
            lastScreenChange = now
        }
        let animating = stepEffects(now: CACurrentMediaTime(), dt: dt)
        if animating { needsRender = true }

        // 120 Hz while the user is interacting, 60 Hz while the Mac's screen or an effect is
        // changing, and 30 Hz when nothing is happening (a touch brings it straight back up).
        let wanted: Float = now - lastActivity < 1 ? 120 : (now - lastScreenChange < 1 || animating) ? 60 : 30
        if link.preferredFrameRateRange.preferred != wanted {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, wanted), maximum: wanted, preferred: wanted)
        }
        render()
    }

    private func render() {
        guard needsRender, let renderer, bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return }
        needsRender = false
        let vp = session.viewport
        renderer.draw(in: metalLayer, frame: vp.contentFrame, bounds: bounds.size,
                      crisp: vp.scale * traitCollection.displayScale >= 2, fx: currentFX(now: CACurrentMediaTime()))
        updateCursorPosition()
    }

    // MARK: SessionDisplay

    func framebufferDidChange() {
        renderer?.setSurface(session.surface)
        startMaterialise()
        needsRender = true
    }

    // MARK: Effects

    // The Effects setting, Reduce Motion and Low Power Mode, as the rest of the app sees them.
    private var theme: SkyTheme { .shared }

    private func startMaterialise() {
        guard theme.motion else { return }
        materialiseStart = CACurrentMediaTime()
    }

    private func addRipple(atContentPoint p: CGPoint) {
        guard theme.motion else { return }
        ripples.append(Ripple(point: session.viewport.toView(p), start: CACurrentMediaTime(), strength: 1))
        if ripples.count > 4 { ripples.removeFirst(ripples.count - 4) }
        needsRender = true
    }

    /// Advances effect animations; returns true while any of them still needs frames.
    private func stepEffects(now: CFTimeInterval, dt: CFTimeInterval) -> Bool {
        let on = theme.effectsOn
        ripples.removeAll { now - $0.start > 1.2 && !Self.fxPreview.contains("-fxRipple") }
        // Reconnect frost: the last frame frosts over while we're not connected.
        let connected = session.status == .connected
        if connected && !wasConnected && session.surface != nil && wasConnectedOnce { startMaterialise() }
        if connected { wasConnectedOnce = true }
        wasConnected = connected
        var frostTarget: Float = (on && !connected && session.surface != nil && !session.isDemo) ? 1 : 0
        if Self.fxPreview.contains("-fxFrost") { frostTarget = 1 }
        frost += (frostTarget - frost) * Float(min(dt * 4, 1))
        if abs(frostTarget - frost) < 0.002 { frost = frostTarget }
        // Precision loupe while a drag is held for a moment.
        if session.isButtonHeld { heldSince = heldSince ?? now } else { heldSince = nil }
        var loupeTarget: Float = (on && heldSince.map { now - $0 > 0.25 } == true) ? 1 : 0
        if Self.fxPreview.contains("-fxLoupe") { loupeTarget = 1 }
        if Self.fxPreview.contains("-fxRipple"), ripples.isEmpty {
            ripples.append(Ripple(point: session.viewport.toView(session.pointer), start: now - 0.25, strength: 1))
        }
        loupeAmount += (loupeTarget - loupeAmount) * Float(min(dt * 12, 1))
        if abs(loupeTarget - loupeAmount) < 0.01 { loupeAmount = loupeTarget }
        if let s = materialiseStart, now - s > 1.0 { materialiseStart = nil }
        // Frost only animates while settling or reconnecting; a settled frost is a still image.
        let frostAnimating = (frost > 0 && frost < 1) || (frost > 0 && session.status == .connecting)
        return !ripples.isEmpty || materialiseStart != nil || frostAnimating || loupeAmount > 0
    }

    private func currentFX(now: CFTimeInterval) -> FramebufferRenderer.FX {
        var fx = FramebufferRenderer.FX()
        fx.time = Float(now.truncatingRemainder(dividingBy: 1000))
        fx.motion = theme.motion ? 1 : 0
        if let s = materialiseStart { fx.materialise = Float(min(max((now - s) / 0.9, 0), 1)) }
        if Self.fxPreview.contains("-fxMaterialise") { fx.materialise = 0.45 }
        fx.frost = frost
        let frozen = Self.fxPreview.contains("-fxRipple")
        let rs = ripples.prefix(4).map { SIMD4<Float>(Float($0.point.x), Float($0.point.y), frozen ? 0.18 : Float(now - $0.start), $0.strength) }
        fx.rippleCount = Float(rs.count)
        var t: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
        if rs.count > 0 { t.0 = rs[0] }; if rs.count > 1 { t.1 = rs[1] }
        if rs.count > 2 { t.2 = rs[2] }; if rs.count > 3 { t.3 = rs[3] }
        fx.ripples = t
        if loupeAmount > 0 {
            let src = session.viewport.toView(session.pointer)
            let radius = 92 * CGFloat(loupeAmount)
            // Direct touch: the finger covers the pointer, so lift the lens above it.
            let lift: CGFloat = (inputModeOverride ?? session.inputMode) == .direct ? 124 : 0
            var c = CGPoint(x: src.x, y: src.y - lift)
            c.x = min(max(c.x, radius), bounds.width - radius)
            c.y = min(max(c.y, radius), bounds.height - radius)
            fx.loupeOn = 1
            fx.loupeRadius = Float(max(radius, 1))
            fx.loupeCenter = SIMD2(Float(c.x), Float(c.y))
            fx.loupeSource = SIMD2(Float(src.x), Float(src.y))
            fx.loupeZoom = 2.2
        }
        return fx
    }

    func cursorDidChange() {
        updateCursorImage()
        needsRender = true
    }

    func viewportDidChange() { needsRender = true }

    // MARK: Cursor

    private var cursorImage: CGImage?
    private var cursorHotspot: CGPoint = .zero

    private func updateCursorImage() {
        if let c = session.cursor, !c.hidden, c.image != nil {
            cursorImage = c.image
            cursorHotspot = c.hotspot
        } else {
            // No shape from the Mac yet (or an empty one): show our arrow rather than nothing.
            cursorImage = Self.defaultArrow
            cursorHotspot = CGPoint(x: 2, y: 2)
        }
        cursorLayer.contents = cursorImage
    }

    private func updateCursorPosition() {
        guard let img = cursorImage, session.viewport.hasContent else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = false   // was left hidden if the cursor came before the first frame
        let vp = session.viewport
        // Remote cursor pixels at the canvas scale, but never smaller than 20 pt tall.
        let s = max(vp.scale, 20 / CGFloat(max(img.height, 1)))
        let p = vp.toView(session.pointer)
        cursorLayer.frame = CGRect(x: p.x - cursorHotspot.x * s, y: p.y - cursorHotspot.y * s,
                                   width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
    }

    /// Fallback arrow until the server sends its cursor (and for the demo session).
    private static let defaultArrow: CGImage? = {
        let size = CGSize(width: 34, height: 50)
        let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return r.image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 2, y: 2))
            p.addLine(to: CGPoint(x: 2, y: 40))
            p.addLine(to: CGPoint(x: 11, y: 31))
            p.addLine(to: CGPoint(x: 18, y: 47))
            p.addLine(to: CGPoint(x: 24, y: 44))
            p.addLine(to: CGPoint(x: 17, y: 29))
            p.addLine(to: CGPoint(x: 29, y: 29))
            p.close()
            UIColor.black.setFill(); p.fill()
            UIColor.white.setStroke(); p.lineWidth = 2.5; p.stroke()
        }.cgImage
    }()

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.stopMomentum()
        for t in touches where t.type == .indirectPointer { pointerTouchBegan(t, event: event) }
        for t in touches where t.type != .indirectPointer {
            touchIDs[ObjectIdentifier(t)] = nextTouchID
            nextTouchID += 1
        }
        feed(event, ending: [])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer { pointerTouchMoved(t) }
        feed(event, ending: [])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer { pointerTouchEnded(t) }
        feed(event, ending: touches)
        touches.forEach { touchIDs[ObjectIdentifier($0)] = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .indirectPointer { pointerTouchEnded(t) }
        touches.forEach { touchIDs[ObjectIdentifier($0)] = nil }
        input.handle(interpreter.cancel())
        needsRender = true
    }

    func markActive() {
        lastActivity = CACurrentMediaTime()
        needsRender = true
    }

    private func feed(_ event: UIEvent?, ending: Set<UITouch>) {
        var active: [Int: CGPoint] = [:]
        var time = CACurrentMediaTime()
        for t in event?.allTouches ?? [] where t.view === self && t.type != .indirectPointer {
            if let last = event?.timestamp { time = last }
            guard !ending.contains(t), t.phase != .ended, t.phase != .cancelled,
                  let id = touchIDs[ObjectIdentifier(t)] else { continue }
            active[id] = t.location(in: self)
        }
        interpreter.mode = inputModeOverride ?? session.inputMode
        input.handle(interpreter.update(touches: active, time: time))
        lastActivity = CACurrentMediaTime()
        needsRender = true
    }
}

/// Weak hop from the update link to the view.
private final class DisplayLinkProxy: NSObject {
    weak var view: RemoteCanvasView?
    init(_ view: RemoteCanvasView) { self.view = view }
    @objc func update(_ link: UIUpdateLink, info: UIUpdateInfo) {
        if let view { view.tick(link, info) } else { link.isEnabled = false }
    }
}
