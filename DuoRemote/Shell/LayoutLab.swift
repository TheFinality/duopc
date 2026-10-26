#if DEBUG
import SwiftUI

/// One screenshot to check size adaptation: SessionScreen in fixed frames, scaled to fit.
/// Sizes in points: iPhone 17 Pro 402×874; Duo outer 466×678, inner 669×951 (from the
/// iphone-duo playbook; assumptions). Static frames have no real fold, so the fold split can only be
/// seen on the Duo simulator itself.
struct LayoutLab: View {
    @State private var coordinator = SessionCoordinator(store: HostStore())
    @State private var sessions = (0..<5).map { _ in VNCSession.demo() }

    private let canvas = CGSize(width: 1810, height: 1880)
    private struct Cell { let name: String; let size: CGSize; let origin: CGPoint }
    private var cells: [Cell] {[
        .init(name: "iPhone 17 Pro portrait", size: .init(width: 402, height: 874), origin: .init(x: 0, y: 30)),
        .init(name: "iPhone 17 Pro landscape", size: .init(width: 874, height: 402), origin: .init(x: 432, y: 30)),
        .init(name: "Duo folded (outer)", size: .init(width: 466, height: 678), origin: .init(x: 1336, y: 30)),
        .init(name: "Duo unfolded portrait", size: .init(width: 669, height: 951), origin: .init(x: 0, y: 964)),
        .init(name: "Duo unfolded landscape", size: .init(width: 951, height: 669), origin: .init(x: 729, y: 964)),
    ]}

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
            ZStack(alignment: .topLeading) {
                ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                    SessionScreen(session: sessions[i], coordinator: coordinator)
                        .frame(width: c.size.width, height: c.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 40))
                        .overlay(RoundedRectangle(cornerRadius: 40).stroke(.secondary, lineWidth: 2))
                        .offset(x: c.origin.x, y: c.origin.y)
                    Text(c.name).font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .offset(x: c.origin.x, y: c.origin.y - 30)
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(Color(.systemBackground))
    }
}
#endif
