import CoreGraphics
import UIKit

/// All of the canvas coordinate maths in one place. Pure value type, unit-tested.
///
/// Content (the remote framebuffer, in pixels) is drawn at `scale` points per pixel with its
/// origin at `offset` in view points:  view = content·scale + offset,  content = (view − offset)/scale.
/// `insets` are the view edges covered by chrome (key bar, keyboard, safe areas): fit and
/// clamping work against the visible rect inside them, so content can scroll out from under it.
struct Viewport: Equatable {
    private(set) var contentSize: CGSize = .zero
    private(set) var bounds: CGSize = .zero
    private(set) var insets: UIEdgeInsets = .zero
    private(set) var displayScale: CGFloat = 3
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    /// True while the user hasn't zoomed away from fit; fit is re-applied on every resize.
    private(set) var isFit = true

    var hasContent: Bool { contentSize.width > 0 && contentSize.height > 0 && bounds.width > 0 && bounds.height > 0 }

    var visibleRect: CGRect {
        let r = CGRect(x: insets.left, y: insets.top,
                       width: bounds.width - insets.left - insets.right,
                       height: bounds.height - insets.top - insets.bottom)
        return r.width > 1 && r.height > 1 ? r : CGRect(origin: .zero, size: bounds)
    }

    var fitScale: CGFloat {
        guard hasContent else { return 1 }
        let v = visibleRect
        return min(v.width / contentSize.width, v.height / contentSize.height)
    }

    /// One remote pixel per device pixel.
    var actualPixelsScale: CGFloat { 1 / displayScale }
    var minScale: CGFloat { fitScale }
    var maxScale: CGFloat { max(fitScale, 4 * actualPixelsScale) }

    /// The content rect in view points.
    var contentFrame: CGRect {
        CGRect(origin: offset, size: CGSize(width: contentSize.width * scale, height: contentSize.height * scale))
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    func toContent(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    /// Clamps a content point to the framebuffer's pixel grid.
    func clampToContent(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), max(contentSize.width - 1, 0)),
                y: min(max(p.y, 0), max(contentSize.height - 1, 0)))
    }

    // MARK: Changes from outside

    mutating func setContentSize(_ size: CGSize) {
        guard size != contentSize else { return }
        let wasEmpty = !hasContent
        contentSize = size
        if wasEmpty || isFit { applyFit() } else { setScale(scale, keeping: visibleCenterContent) }
    }

    /// Window size, chrome insets or screen scale changed. Keeps the content point at the
    /// visible centre where it was (or stays at fit).
    mutating func setBounds(_ size: CGSize, insets: UIEdgeInsets, displayScale: CGFloat) {
        guard size != bounds || insets != self.insets || displayScale != self.displayScale else { return }
        let anchor = hasContent ? visibleCenterContent : nil
        bounds = size
        self.insets = insets
        self.displayScale = displayScale
        guard hasContent else { return }
        if isFit { applyFit() } else if let anchor { setScale(scale, keeping: anchor) }
    }

    // MARK: Gestures

    mutating func pan(by d: CGVector) {
        offset.x += d.dx
        offset.y += d.dy
        clampOffset()
    }

    /// Zooms by `factor` keeping the view point `anchor` over the same content point.
    mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard hasContent, factor.isFinite, factor > 0 else { return }
        let newScale = min(max(scale * factor, minScale), maxScale)
        let ratio = newScale / scale
        offset = CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio,
                         y: anchor.y - (anchor.y - offset.y) * ratio)
        scale = newScale
        clampOffset()
        isFit = abs(scale - fitScale) < 0.0001
    }

    mutating func zoomToFit() {
        applyFit()
    }

    /// 1 remote pixel → 1 device pixel, centred on `contentPoint`.
    mutating func zoomToActualPixels(around contentPoint: CGPoint) {
        guard hasContent else { return }
        setScale(min(max(actualPixelsScale, minScale), maxScale), keeping: contentPoint)
        isFit = abs(scale - fitScale) < 0.0001
    }

    /// Scrolls just enough to keep `contentPoint` (the pointer) inside the visible rect less `margin`.
    mutating func follow(_ contentPoint: CGPoint, margin: CGFloat = 24) {
        guard hasContent else { return }
        let p = toView(contentPoint)
        var r = visibleRect.insetBy(dx: margin, dy: margin)
        if r.width < 1 || r.height < 1 { r = visibleRect }
        var d = CGVector.zero
        if p.x < r.minX { d.dx = r.minX - p.x } else if p.x > r.maxX { d.dx = r.maxX - p.x }
        if p.y < r.minY { d.dy = r.minY - p.y } else if p.y > r.maxY { d.dy = r.maxY - p.y }
        if d != .zero { pan(by: d) }
    }

    // MARK: Internals

    private var visibleCenterContent: CGPoint {
        let v = visibleRect
        return toContent(CGPoint(x: v.midX, y: v.midY))
    }

    private mutating func applyFit() {
        guard hasContent else { return }
        scale = fitScale
        isFit = true
        clampOffset()   // content ≤ visible on both axes → centred
    }

    /// Sets the scale so `contentPoint` lands at the visible centre, then clamps.
    private mutating func setScale(_ s: CGFloat, keeping contentPoint: CGPoint) {
        scale = min(max(s, minScale), maxScale)
        let v = visibleRect
        offset = CGPoint(x: v.midX - contentPoint.x * scale, y: v.midY - contentPoint.y * scale)
        clampOffset()
    }

    private mutating func clampOffset() {
        let v = visibleRect
        offset.x = Self.clampAxis(offset.x, extent: contentSize.width * scale, visibleMin: v.minX, visibleLength: v.width)
        offset.y = Self.clampAxis(offset.y, extent: contentSize.height * scale, visibleMin: v.minY, visibleLength: v.height)
    }

    /// Content smaller than the visible span → centred in it. Larger → it must cover the span.
    static func clampAxis(_ o: CGFloat, extent: CGFloat, visibleMin: CGFloat, visibleLength: CGFloat) -> CGFloat {
        if extent <= visibleLength { return visibleMin + (visibleLength - extent) / 2 }
        return min(max(o, visibleMin + visibleLength - extent), visibleMin)
    }
}
