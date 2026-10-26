import SwiftUI
import UIKit

/// The remote screen: framebuffer rendering, zoom/pan and touch → mouse.
/// `obscuredInsets` are the edges covered by chrome (key bar, keyboard, safe areas): the canvas
/// still draws under them, but fits and scrolls so content can be brought out from beneath.
struct RemoteCanvas: UIViewRepresentable {
    let session: VNCSession
    var obscuredInsets: EdgeInsets
    /// Forces an input mode regardless of the session's (laptop pose: the screen half is direct touch).
    var inputModeOverride: InputMode?

    init(session: VNCSession, obscuredInsets: EdgeInsets = EdgeInsets(), inputModeOverride: InputMode? = nil) {
        self.session = session
        self.obscuredInsets = obscuredInsets
        self.inputModeOverride = inputModeOverride
    }

    func makeUIView(context: Context) -> RemoteCanvasView {
        RemoteCanvasView(session: session)
    }

    func updateUIView(_ view: RemoteCanvasView, context: Context) {
        view.attach(session)
        view.inputModeOverride = inputModeOverride
        let rtl = context.environment.layoutDirection == .rightToLeft
        view.obscuredInsets = UIEdgeInsets(top: obscuredInsets.top,
                                           left: rtl ? obscuredInsets.trailing : obscuredInsets.leading,
                                           bottom: obscuredInsets.bottom,
                                           right: rtl ? obscuredInsets.leading : obscuredInsets.trailing)
    }
}
