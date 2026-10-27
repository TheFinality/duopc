import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import os

extension Logger {
    nonisolated static let outerScreen = Logger(subsystem: AppInfo.bundleID, category: "outer-screen")
}

/// A picture of your choosing on the Duo's outer screen (the back of the lid in laptop pose).
/// iOS shows app content there, while the app is open on the inner screen, only as a camera
/// capture accessory, which needs a running camera session: so while the picture is up, a camera
/// runs at its lowest resolution and frame rate, and its frames are dropped unread.
enum OuterPicture {
    static let enabledKey = "outerPicture"
    /// Bumped on every change of picture, so views reload it; 0 when there's none.
    static let versionKey = "outerPictureVersion"
    nonisolated static let maxPixels = 2048

    /// Stays on this device (Application Support isn't shared, and no file leaves the app).
    nonisolated static var fileURL: URL { .applicationSupportDirectory.appending(path: "OuterPicture.jpg") }

    static func load() -> UIImage? { UIImage(contentsOfFile: fileURL.path) }

    nonisolated static func save(_ jpeg: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove() { try? FileManager.default.removeItem(at: fileURL) }

    /// A photo (any format ImageIO reads, HEIC included) as an upright JPEG no bigger than
    /// `maxPixels` on its longer side; nil if it isn't an image.
    nonisolated static func prepare(_ data: Data, maxPixels: Int = maxPixels) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The camera runs only while the picture can actually be shown: turned on, chosen, the
    /// device unfolded (closed, the app itself is on the outer screen) and the app in front.
    nonisolated static func cameraShouldRun(enabled: Bool, hasPicture: Bool, unfolded: Bool, active: Bool) -> Bool {
        enabled && hasPicture && unfolded && active
    }
}

/// The camera session that keeps the outer screen available. Used on its own queue only.
nonisolated final class OuterPictureCamera: @unchecked Sendable {
    static let shared = OuterPictureCamera()

    private let queue = DispatchQueue(label: "outer-picture-camera")
    private var session: AVCaptureSession?

    func setRunning(_ run: Bool) {
        queue.async { [self] in run ? start() : stop() }
    }

    private func start() {
        guard session == nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.low) { session.sessionPreset = .low }
        guard session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input)
        // No delegate: frames are dropped as they arrive. The output only makes the camera stream,
        // so the session counts as active.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        // The slowest frame rate the camera allows; set after starting, which applies the preset.
        if let slowest = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameDuration).max(),
           (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = slowest
            device.activeVideoMaxFrameDuration = slowest
            device.unlockForConfiguration()
        }
        self.session = session
        Logger.outerScreen.info("camera on for the outer screen")
    }

    private func stop() {
        guard let session else { return }
        session.stopRunning()
        self.session = nil
        Logger.outerScreen.info("camera off")
    }
}

/// Puts the chosen picture on the outer screen while this view is shown.
struct OuterPictureAccessory: ViewModifier {
    let unfolded: Bool

    @AppStorage(OuterPicture.enabledKey) private var enabled = false
    @AppStorage(OuterPicture.versionKey) private var version = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var picture: UIImage?
    /// `wanted`, except that turning off waits a moment: the hinge readings flicker while it
    /// moves, and each blink stopped the camera and took the picture away.
    @State private var showing = false
    @State private var settle: Task<Void, Never>?

    private var wanted: Bool {
        OuterPicture.cameraShouldRun(enabled: enabled, hasPicture: picture != nil, unfolded: unfolded,
                                     active: scenePhase == .active)
    }

    func body(content: Content) -> some View {
        content
            .sceneAccessory {
                CameraCaptureAccessory(isEnabled: .constant(showing)) {
                    OuterPictureView(picture: picture)
                }
                .onAvailabilityChange { available in
                    Logger.outerScreen.info("outer screen \(available ? "available" : "unavailable", privacy: .public)")
                }
            }
            .task(id: version) { picture = version > 0 ? OuterPicture.load() : nil }
            .onChange(of: wanted, initial: true) { _, wanted in
                settle?.cancel()
                if wanted || !enabled || scenePhase != .active {
                    showing = wanted
                } else {
                    settle = Task {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { showing = false }
                    }
                }
            }
            .onChange(of: showing, initial: true) { _, showing in OuterPictureCamera.shared.setRunning(showing) }
            .onDisappear {
                settle?.cancel()
                OuterPictureCamera.shared.setRunning(false)
            }
    }
}

private struct OuterPictureView: View {
    let picture: UIImage?

    var body: some View {
        Color.black
            .overlay {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
