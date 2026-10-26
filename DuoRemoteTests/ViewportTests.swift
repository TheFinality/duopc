import Testing
import UIKit
@testable import DuoRemote

@MainActor
struct ViewportTests {
    func make(content: CGSize = CGSize(width: 2880, height: 1800),
              bounds: CGSize = CGSize(width: 402, height: 874),
              insets: UIEdgeInsets = .zero) -> Viewport {
        var v = Viewport()
        v.setBounds(bounds, insets: insets, displayScale: 3)
        v.setContentSize(content)
        return v
    }

    @Test func fitsAndCentres() {
        let v = make()
        #expect(abs(v.scale - 402.0 / 2880) < 1e-9)
        #expect(v.isFit)
        #expect(abs(v.contentFrame.midY - 437) < 1e-6)
        #expect(abs(v.contentFrame.minX) < 1e-6)
    }

    @Test func fitUsesVisibleRect() {
        let v = make(insets: UIEdgeInsets(top: 0, left: 0, bottom: 100, right: 0))
        #expect(abs(v.contentFrame.midY - 387) < 1e-6)
    }

    @Test func mappingRoundTrips() {
        var v = make()
        v.zoom(by: 3, anchor: CGPoint(x: 100, y: 300))
        let p = CGPoint(x: 1234, y: 567)
        let back = v.toContent(v.toView(p))
        #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
    }

    @Test func zoomKeepsAnchorOverSameContent() {
        var v = make()
        let anchor = CGPoint(x: 200, y: 437)
        let before = v.toContent(anchor)
        v.zoom(by: 2, anchor: anchor)
        let after = v.toContent(anchor)
        #expect(abs(before.x - after.x) < 1e-6 && abs(before.y - after.y) < 1e-6)
        #expect(!v.isFit)
    }

    @Test func zoomIsClampedToRange() {
        var v = make()
        v.zoom(by: 0.1, anchor: .zero)
        #expect(abs(v.scale - v.fitScale) < 1e-9)
        v.zoom(by: 1000, anchor: .zero)
        #expect(abs(v.scale - 4.0 / 3) < 1e-9)
    }

    @Test func panIsClampedToContent() {
        var v = make()
        v.zoom(by: 4, anchor: .zero)
        v.pan(by: CGVector(dx: 10_000, dy: 10_000))
        #expect(v.contentFrame.minX == 0 && v.contentFrame.minY == 0)
        v.pan(by: CGVector(dx: -100_000, dy: -100_000))
        #expect(abs(v.contentFrame.maxX - 402) < 1e-6 && abs(v.contentFrame.maxY - 874) < 1e-6)
    }

    @Test func followKeepsPointerVisible() {
        var v = make()
        v.zoom(by: 6, anchor: .zero)
        let p = CGPoint(x: 2800, y: 1700)
        v.follow(p)
        let vp = v.toView(p)
        #expect(vp.x <= 402 - 24 + 1e-6 && vp.y <= 874 - 24 + 1e-6)
    }

    @Test func resizeKeepsCentreAndFit() {
        var v = make()
        v.setBounds(CGSize(width: 874, height: 402), insets: .zero, displayScale: 3)
        #expect(v.isFit && abs(v.scale - 402.0 / 1800) < 1e-9)

        v.zoom(by: 3, anchor: CGPoint(x: 437, y: 201))
        let centre = v.toContent(CGPoint(x: 437, y: 201))
        v.setBounds(CGSize(width: 600, height: 400), insets: .zero, displayScale: 3)
        let after = v.toContent(CGPoint(x: 300, y: 200))
        #expect(abs(centre.x - after.x) < 1 && abs(centre.y - after.y) < 1)
    }
}
