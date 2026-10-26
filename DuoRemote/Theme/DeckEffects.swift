import SwiftUI

/// Touch points on the trackpad, in the trackpad's own coordinates, published for the rim glow.
@Observable
final class TrackpadTouches {
    var points: [CGPoint] = []
}

/// Neon rim around a rounded rectangle: a conic gradient that turns once every ~120 s, a few
/// sparkles drifting along it, and a brighter patch near each finger.
struct NeonRim: View {
    var touches: [CGPoint] = []
    var cornerRadius: CGFloat = 20
    var lineWidth: CGFloat = 3
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let theme = SkyTheme.shared
        let rim = theme.rim
        let motion = theme.motion
        let sparkles = 3 + Int((theme.starAmount * 5).rounded())
        if !theme.effectsOn {
            // Effects off: a plain hairline instead of the glowing rim.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        } else {
        // The rim's colours turn slowly: 10 fps is plenty until a finger is down.
        TimelineView(.animation(minimumInterval: touches.isEmpty ? 1.0 / 10 : 1.0 / 30, paused: !motion || scenePhase != .active)) { ctx in
            let t = motion ? ctx.date.timeIntervalSinceReferenceDate : 0
            Canvas { gc, size in
                draw(&gc, size: size, t: t, rim: rim, sparkles: motion ? sparkles : 0)
            }
        }
        .allowsHitTesting(false)
        }
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double, rim: [Color], sparkles: Int) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
        let shading = GraphicsContext.Shading.conicGradient(
            Gradient(colors: rim + [rim[0]]), center: CGPoint(x: rect.midX, y: rect.midY),
            angle: .degrees(t / 120 * 360))

        gc.drawLayer { l in
            l.opacity = 0.65
            l.addFilter(.blur(radius: 5))
            l.stroke(path, with: shading, lineWidth: lineWidth * 2)
        }
        gc.stroke(path, with: shading, lineWidth: lineWidth)

        // Finger glow: the same rim, brighter, masked to a radial patch around each touch.
        let full = Path(CGRect(origin: .zero, size: size))
        for p in touches {
            gc.drawLayer { l in
                l.stroke(path, with: shading, lineWidth: lineWidth + 1.5)
                l.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: lineWidth - 1)
                l.blendMode = .destinationIn
                l.fill(full, with: .radialGradient(Gradient(colors: [.white, .clear]), center: p, startRadius: 0, endRadius: 80))
            }
            gc.drawLayer { l in
                l.opacity = 0.8
                l.addFilter(.blur(radius: 6))
                l.stroke(path, with: shading, lineWidth: lineWidth * 2.2)
                l.blendMode = .destinationIn
                l.fill(full, with: .radialGradient(Gradient(colors: [.white, .clear]), center: p, startRadius: 0, endRadius: 70))
            }
        }

        guard sparkles > 0 else { return }
        for i in 0..<sparkles {
            let s = Double(i)
            let period = 5 + (s * 1.7).truncatingRemainder(dividingBy: 4)
            let phase = t / period + s * 0.37
            let life = phase - phase.rounded(.down)
            let alpha = sin(.pi * life)
            let base = (s * 0.173 + phase.rounded(.down) * 0.31).truncatingRemainder(dividingBy: 1)
            let u = (base + life * 0.07).truncatingRemainder(dividingBy: 1)
            let p = Self.perimeterPoint(u, rect: rect, radius: cornerRadius)
            let c = rim[i % rim.count]
            gc.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(c.opacity(alpha * 0.35)))
            gc.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)), with: .color(.white.opacity(alpha * 0.95)))
        }
    }

    /// A point `u` (0...1) of the way round a rounded rectangle, clockwise from the top-left.
    static func perimeterPoint(_ u: Double, rect: CGRect, radius r: CGFloat) -> CGPoint {
        let w = rect.width - 2 * r, h = rect.height - 2 * r
        let arc = Double.pi * r / 2
        var d = u * (2 * w + 2 * h + 4 * arc)
        func theta(_ d: Double) -> Double { d / Double(r) }
        if d < w { return CGPoint(x: rect.minX + r + d, y: rect.minY) }
        d -= w
        if d < arc { let a = theta(d); return CGPoint(x: rect.maxX - r + r * sin(a), y: rect.minY + r - r * cos(a)) }
        d -= arc
        if d < h { return CGPoint(x: rect.maxX, y: rect.minY + r + d) }
        d -= h
        if d < arc { let a = theta(d); return CGPoint(x: rect.maxX - r + r * cos(a), y: rect.maxY - r + r * sin(a)) }
        d -= arc
        if d < w { return CGPoint(x: rect.maxX - r - d, y: rect.maxY) }
        d -= w
        if d < arc { let a = theta(d); return CGPoint(x: rect.minX + r - r * sin(a), y: rect.maxY - r + r * cos(a)) }
        d -= arc
        if d < h { return CGPoint(x: rect.minX, y: rect.maxY - r - d) }
        d -= h
        let a = theta(d)
        return CGPoint(x: rect.minX + r - r * cos(a), y: rect.minY + r - r * sin(a))
    }
}

/// A fixed-seed starfield with 2-3 slowly pulsing four-point twinkles. Draws nothing by day.
struct StarField: View {
    @Environment(\.scenePhase) private var scenePhase

    private static let stars: [(x: Double, y: Double, size: Double, alpha: Double)] = {
        var seed: UInt64 = 0x5EED_2024
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0..<70).map { _ in (next(), next(), 0.5 + next() * 0.9, 0.25 + next() * 0.6) }
    }()

    var body: some View {
        let theme = SkyTheme.shared
        let amount = theme.starAmount
        let motion = theme.motion
        if amount > 0, theme.effectsOn {
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !motion || scenePhase != .active)) { ctx in   // slow twinkle
                let t = motion ? ctx.date.timeIntervalSinceReferenceDate : 0
                Canvas { gc, size in
                    gc.opacity = amount
                    for (i, s) in Self.stars.enumerated() {
                        let p = CGPoint(x: s.x * size.width, y: s.y * size.height)
                        if i < 3 {
                            let pulse = 0.5 + 0.5 * sin(t * 0.9 + Double(i) * 2.1)
                            Self.fourPoint(&gc, at: p, radius: 3 + 3 * pulse, alpha: 0.5 + 0.5 * pulse)
                        } else {
                            gc.fill(Path(ellipseIn: CGRect(x: p.x - s.size / 2, y: p.y - s.size / 2, width: s.size, height: s.size)),
                                    with: .color(.white.opacity(s.alpha)))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private static func fourPoint(_ gc: inout GraphicsContext, at p: CGPoint, radius r: Double, alpha: Double) {
        var path = Path()
        let k = r * 0.18
        path.move(to: CGPoint(x: p.x, y: p.y - r))
        path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + k, y: p.y - k))
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x + k, y: p.y + k))
        path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - k, y: p.y + k))
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x - k, y: p.y - k))
        gc.fill(path, with: .color(.white.opacity(alpha)))
    }
}

/// Soft pulsing outline for a latched modifier; a steady glow with a slow shimmer when locked.
struct ModifierGlow: View {
    let locked: Bool
    let color: Color
    var cornerRadius: CGFloat = 12
    @State private var on = false

    var body: some View {
        let motion = SkyTheme.shared.motion
        let pulse = Animation.easeInOut(duration: locked ? 2.8 : 0.9).repeatForever(autoreverses: true)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 2)
            .shadow(color: color.opacity(0.9), radius: locked ? (on ? 9 : 6) : (on ? 10 : 3))
            .opacity(locked ? (on ? 1 : 0.8) : (on ? 1 : 0.45))
            .animation(motion ? pulse : nil, value: on)
            .onAppear { on = motion }
            .allowsHitTesting(false)
    }
}

/// One diagonal specular sheen sweeping across the view when it first appears (~0.9 s).
struct FoldLightSweep: ViewModifier {
    @State private var progress: CGFloat = 0
    @State private var played = false

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let w = proxy.size.width
                LinearGradient(colors: [.clear, .white.opacity(0.22), .white.opacity(0.05), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.45)
                    .rotationEffect(.degrees(18))
                    .frame(width: w * 0.45, height: proxy.size.height * 1.6)
                    .offset(x: -w * 0.45 + progress * w * 1.45, y: -proxy.size.height * 0.3)
                    .blendMode(.plusLighter)
            }
            .clipped()
            .allowsHitTesting(false)
        }
        .onAppear {
            guard !played, SkyTheme.shared.motion else { return }
            played = true
            withAnimation(.easeInOut(duration: 0.9)) { progress = 1 }
        }
    }
}

extension View {
    func foldLightSweep() -> some View { modifier(FoldLightSweep()) }
}
