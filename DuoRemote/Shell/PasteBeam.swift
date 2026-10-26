import SwiftUI
import UIKit

/// Remembers where the Paste button is and fires the "paste beam": a streak of light that flies
/// from the button to the top of the screen. The overlay lives at SessionScreen level.
@Observable
final class PasteBeam {
    static let shared = PasteBeam()

    @ObservationIgnored var buttonFrame: CGRect = .zero    // global coordinates
    private(set) var origin: CGPoint = .zero
    private(set) var fireCount = 0

    func fire() {
        guard SkyTheme.shared.motion, buttonFrame != .zero else { return }
        origin = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        fireCount += 1
    }
}

extension VNCSession {
    /// Types the iPhone's clipboard on the Mac, with the beam. Reading the pasteboard shows
    /// iOS's own "Allow Paste" prompt. Multi-line or long text waits in `pendingPaste` for the
    /// shell to confirm.
    func pasteClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if KeyMapping.pasteNeedsConfirmation(KeyMapping.pasteLines(text)) {
            pendingPaste = text
        } else {
            sendPaste(text)
        }
    }

    func confirmPaste() {
        guard let text = pendingPaste else { return }
        pendingPaste = nil
        sendPaste(text)
    }

    private func sendPaste(_ text: String) {
        PasteBeam.shared.fire()
        pasteToMac(text)
    }
}

extension UIApplication {
    /// Hides whichever software keyboard is up (ours or the text box's).
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// Marks the Paste button: its global frame is where the beam starts.
    func pasteBeamSource() -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PasteBeam.shared.buttonFrame = $0 }
    }
}

struct PasteBeamOverlay: View {
    private let beam = PasteBeam.shared

    var body: some View {
        let theme = SkyTheme.shared
        GeometryReader { proxy in
            let o = proxy.frame(in: .global).origin
            let start = CGPoint(x: beam.origin.x - o.x, y: beam.origin.y - o.y)
            Capsule()
                .fill(LinearGradient(colors: [.white, theme.rim[1], theme.rim[1].opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: 4, height: 72)
                .shadow(color: theme.rim[1], radius: 6)
                .keyframeAnimator(initialValue: 0.0, trigger: beam.fireCount) { view, p in
                    view
                        .opacity(sin(.pi * p))
                        .position(x: start.x, y: start.y - 36 - p * (start.y + 40))
                } keyframes: { _ in
                    CubicKeyframe(1.0, duration: 0.6)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
