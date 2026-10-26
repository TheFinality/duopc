import UIKit
import IOSurface
import CoreVideo

/// A generated 2560×1440 "desktop" in an IOSurface, for the demo session (layout checks,
/// screenshots) — exercises the same zero-copy render path as a real connection.
enum DemoFramebuffer {
    static func make(width: Int = 2560, height: Int = 1440) -> SurfaceBox? {
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: width * 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surface.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Flip to UIKit coordinates (origin top-left).
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let w = CGFloat(width), h = CGFloat(height)
        let bg = CGGradient(colorsSpace: nil, colors: [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: w, y: h), options: [])

        // A 100 px grid, so zoom and pixel crispness are easy to judge.
        UIColor.white.withAlphaComponent(0.15).setStroke()
        let grid = UIBezierPath()
        stride(from: 0, through: w, by: 100).forEach { grid.move(to: CGPoint(x: $0, y: 0)); grid.addLine(to: CGPoint(x: $0, y: h)) }
        stride(from: 0, through: h, by: 100).forEach { grid.move(to: CGPoint(x: 0, y: $0)); grid.addLine(to: CGPoint(x: w, y: $0)) }
        grid.lineWidth = 2
        grid.stroke()

        // A taskbar with centred icons and a clock, like Windows 11.
        UIColor.black.withAlphaComponent(0.45).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: h - 72, width: w, height: 72)).fill()
        for i in 0..<7 {
            UIColor.white.withAlphaComponent(i == 0 ? 0.9 : 0.55).setFill()
            UIBezierPath(roundedRect: CGRect(x: w / 2 - 280 + CGFloat(i) * 80, y: h - 58, width: 44, height: 44), cornerRadius: 10).fill()
        }
        let clock: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: UIColor.white]
        ("12:00" as NSString).draw(at: CGPoint(x: w - 110, y: h - 52), withAttributes: clock)

        // A window with text at a realistic size.
        UIColor.systemBackground.resolvedColor(with: .init(userInterfaceStyle: .light)).setFill()
        UIBezierPath(roundedRect: CGRect(x: 300, y: 260, width: 1500, height: 900), cornerRadius: 24).fill()
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: UIColor.black]
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.darkGray]
        ("\(AppInfo.name) demo" as NSString).draw(at: CGPoint(x: 360, y: 320), withAttributes: title)
        ("2560 × 1440 test pattern · no network · grid every 100 px\nThe quick brown fox jumps over the lazy dog. 0123456789" as NSString)
            .draw(in: CGRect(x: 360, y: 430, width: 1380, height: 200), withAttributes: body)
        for (i, c) in [UIColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple].enumerated() {
            c.setFill()
            UIBezierPath(roundedRect: CGRect(x: 360 + CGFloat(i) * 230, y: 700, width: 200, height: 200), cornerRadius: 20).fill()
        }
        return SurfaceBox(surface: surface, size: CGSize(width: width, height: height))
    }
}
