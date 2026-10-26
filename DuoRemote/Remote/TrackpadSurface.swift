import SwiftUI
import UIKit

/// A laptop-style trackpad (the laptop-pose deck). Same touch state machine and pointer maths
/// as the canvas in trackpad mode — it just lives on the other half of the fold. Draws a soft
/// glow under each finger.
struct TrackpadSurface: UIViewRepresentable {
    let session: VNCSession
    var touches: TrackpadTouches?

    init(session: VNCSession, touches: TrackpadTouches? = nil) {
        self.session = session
        self.touches = touches
    }

    func makeUIView(context: Context) -> TrackpadSurfaceView {
        let v = TrackpadSurfaceView(session: session)
        v.touchPoints = touches
        return v
    }
    func updateUIView(_ view: TrackpadSurfaceView, context: Context) {
        view.attach(session)
        view.touchPoints = touches
    }
}

final class TrackpadSurfaceView: UIView {
    /// Published for the deck's rim glow (nil when nobody is listening).
    var touchPoints: TrackpadTouches?
    private var session: VNCSession
    private var interpreter = TouchInterpreter()
    private var input: InputController
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var glows: [Int: CALayer] = [:]
    private var updateLink: UIUpdateLink?
    private var linkProxy: TrackpadLinkProxy?
    private var lastTick: CFTimeInterval = 0
    private let grabHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let clickHaptic = UIImpactFeedbackGenerator(style: .light)

    init(session: VNCSession) {
        self.session = session
        self.input = InputController(session: session)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        interpreter.mode = .trackpad
        wireHaptics()
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(_ s: VNCSession) {
        guard s !== session else { return }
        session = s
        input = InputController(session: s)
        interpreter = TouchInterpreter()
        interpreter.mode = .trackpad
        wireHaptics()
    }

    private func wireHaptics() {
        input.onGrab = { [weak self] in self?.grabHaptic.impactOccurred() }
        input.onClick = { [weak self] in self?.clickHaptic.impactOccurred(intensity: 0.6) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if updateLink == nil {
            let proxy = TrackpadLinkProxy(self)
            linkProxy = proxy
            let link = UIUpdateLink(view: self, actionTarget: proxy, selector: #selector(TrackpadLinkProxy.update(_:info:)))
            link.requiresContinuousUpdates = true
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)   // the canvas does the drawing
            updateLink = link
        }
        updateLink?.isEnabled = window != nil
    }

    fileprivate func tick(_ info: UIUpdateInfo) {
        let now = info.modelTime
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 0.1)
        lastTick = now
        apply(interpreter.tick(time: CACurrentMediaTime()))
        if input.isAnimating {
            input.tick(dt: CGFloat(dt))
            session.display?.viewportDidChange()
        }
        // Nothing to time or animate: sleep until the next touch.
        if interpreter.isIdle, !input.isAnimating { updateLink?.isEnabled = false; lastTick = 0 }
    }

    /// Zoom on the trackpad zooms the screen around the pointer, not around the fingers.
    private func apply(_ intents: [TouchIntent]) {
        guard !intents.isEmpty else { return }
        let anchor = session.viewport.toView(session.pointer)
        input.handle(intents.map {
            if case let .zoom(f, _) = $0 { return .zoom(factor: f, anchor: anchor) }
            return $0
        })
        session.display?.viewportDidChange()   // the cursor moved: redraw the canvas
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateLink?.isEnabled = window != nil
        input.stopMomentum()
        for t in touches { touchIDs[ObjectIdentifier(t)] = nextID; nextID += 1 }
        feed(event, ending: [])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { feed(event, ending: []) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        feed(event, ending: touches)
        touches.forEach { touchIDs[ObjectIdentifier($0)] = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { touchIDs[ObjectIdentifier($0)] = nil }
        apply(interpreter.cancel())
        updateGlows([:])
    }

    private func feed(_ event: UIEvent?, ending: Set<UITouch>) {
        var active: [Int: CGPoint] = [:]
        for t in event?.allTouches ?? [] where t.view === self {
            guard !ending.contains(t), t.phase != .ended, t.phase != .cancelled,
                  let id = touchIDs[ObjectIdentifier(t)] else { continue }
            active[id] = t.location(in: self)
        }
        apply(interpreter.update(touches: active, time: event?.timestamp ?? CACurrentMediaTime()))
        updateGlows(active)
    }

    // MARK: Finger glow

    private func updateGlows(_ active: [Int: CGPoint]) {
        if let touchPoints {
            let pts = active.sorted { $0.key < $1.key }.map(\.value)
            if pts != touchPoints.points { touchPoints.points = pts }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in glows where active[id] == nil {
            layer.removeFromSuperlayer()
            glows[id] = nil
        }
        for (id, p) in active {
            let layer = glows[id] ?? makeGlow()
            glows[id] = layer
            layer.position = p
        }
        CATransaction.commit()
    }

    private func makeGlow() -> CALayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: 90, height: 90)
        layer.addSublayer(g)
        return g
    }
}

private final class TrackpadLinkProxy: NSObject {
    weak var view: TrackpadSurfaceView?
    init(_ view: TrackpadSurfaceView) { self.view = view }
    @objc func update(_ link: UIUpdateLink, info: UIUpdateInfo) {
        if let view { view.tick(info) } else { link.isEnabled = false }
    }
}
