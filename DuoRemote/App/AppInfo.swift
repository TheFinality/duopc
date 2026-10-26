import Foundation
import UIKit

/// The app's name and identifier come from the build settings, so a fork renames it in one place.
nonisolated enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "VNC"
    static let bundleID = Bundle.main.bundleIdentifier ?? "vnc-client"
    /// "iPhone" or "iPad", for wording only (never layout).
    @MainActor static var device: String { UIDevice.current.model }
}
