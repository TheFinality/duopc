import SwiftUI
import UIKit

/// Covers every window of a scene whenever it isn't active, so the app switcher snapshot shows
/// neither the Mac's screen nor any sheet above it (Copy text from screen, the hosts list).
/// A window of its own above everything; driven by UIKit's scene notifications, which arrive
/// before the snapshot is taken.
final class PrivacyShield: NSObject {
    static let shared = PrivacyShield()

    private var covers: [ObjectIdentifier: UIWindow] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(didActivate), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(didDisconnect), name: UIScene.didDisconnectNotification, object: nil)
    }

    @objc private func willDeactivate(_ note: Notification) { cover(note.object as? UIWindowScene) }
    @objc private func didActivate(_ note: Notification) { uncover(note.object as? UIWindowScene) }
    @objc private func didDisconnect(_ note: Notification) { forget(note.object as? UIWindowScene) }

    private func cover(_ scene: UIWindowScene?) {
        guard let scene else { return }
        let key = ObjectIdentifier(scene)
        let window = covers[key] ?? {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: PrivacyCover())
            host.view.backgroundColor = .clear
            window.rootViewController = host
            covers[key] = window
            return window
        }()
        window.isHidden = false
    }

    private func uncover(_ scene: UIWindowScene?) {
        guard let scene else { return }
        covers[ObjectIdentifier(scene)]?.isHidden = true
    }

    private func forget(_ scene: UIWindowScene?) {
        guard let scene else { return }
        covers[ObjectIdentifier(scene)] = nil
    }
}

/// Opaque cover shown whenever the scene isn't active.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.10)
            VStack(spacing: 14) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 48, weight: .medium))
                Text(AppInfo.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .ignoresSafeArea()
    }
}
