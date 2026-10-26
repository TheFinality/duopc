import SwiftUI
import UIKit

@main
struct DuoRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SessionCoordinator(store: HostStore())

    init() {
        Diagnostics.shared.start()
        PrivacyShield.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-layoutLab") {
                    LayoutLab()
                } else {
                    RootView(coordinator: coordinator)
                }
                #else
                RootView(coordinator: coordinator)
                #endif
            }
            .task {
                await coordinator.store.tidyKeychain()
                applyLaunchArguments()
            }
        }
    }

    private func applyLaunchArguments() {
        // DEMO_LAUNCH is set only by the CI launch smoke test, to open the demo in a Release build.
        #if DEBUG || DEMO_LAUNCH
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoSession") { coordinator.openDemo() }
        #endif
        #if DEBUG
        if let i = args.firstIndex(of: "-vncSmoke"), i + 1 < args.count {
            VNCSmokeTest.run(host: args[i + 1])
        }
        #endif
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Only the system keyboard: a third-party one could see what's typed into the PC,
    /// passwords included.
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
