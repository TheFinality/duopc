import UIKit
@preconcurrency import RoyalVNCKit

/// A mouse or trackpad (an iPad keyboard's, or a Bluetooth one): the pointer goes where it points,
/// clicks are real button presses, and wheel/two-finger scrolling and pinching act directly.
/// Finger touches never come here; they go through the TouchInterpreter as before.
extension RemoteCanvasView: UIPointerInteractionDelegate {
    func installPointerInput() {
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(pointerHovered(_:))))

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(pointerScrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []          // scroll events only, never finger drags
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pointerPinched(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(pinch)

        addInteraction(UIPointerInteraction(delegate: self))
    }

    /// Only the Mac's cursor shows over the remote screen.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func pointerHovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        movePointer(toView: g.location(in: self))
    }

    @objc private func pointerScrolled(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let v = g.velocity(in: self)
        input.scrollWheel(by: CGVector(dx: d.x, dy: d.y), speed: CGVector(dx: v.x, dy: v.y).length)
        markActive()
    }

    @objc private func pointerPinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        session.viewport.zoom(by: g.scale, anchor: session.viewport.toView(session.pointer))
        g.scale = 1
        markActive()
    }

    // Clicks from a pointer arrive as touches of type .indirectPointer.

    func pointerTouchBegan(_ t: UITouch, event: UIEvent?) {
        movePointer(toView: t.location(in: self))
        let button: VNCMouseButton = event?.buttonMask.contains(.secondary) == true ? .right : .left
        pointerButton = button
        session.flushPointer()
        session.buttonDown(button)
    }

    func pointerTouchMoved(_ t: UITouch) {
        movePointer(toView: t.location(in: self))
    }

    func pointerTouchEnded(_ t: UITouch) {
        movePointer(toView: t.location(in: self))
        session.flushPointer()
        if let button = pointerButton { session.buttonUp(button) }
        pointerButton = nil
    }

    private func movePointer(toView p: CGPoint) {
        session.movePointer(to: session.viewport.toContent(p))
        markActive()
    }
}
