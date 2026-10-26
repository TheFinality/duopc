@preconcurrency import RoyalVNCKit
import CoreGraphics
import Foundation
import IOSurface
import os

/// A display surface handed across threads: the `FramePresenter` copy of the library's framebuffer,
/// sampled on the GPU.
nonisolated struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
    let size: CGSize
    /// Keeps the surface's owner alive (a decoded video frame's pixel buffer, which VideoToolbox
    /// would otherwise reuse while it's still on screen).
    var owner: AnyObject? = nil
}

/// Set from the library's threads on every framebuffer rect, read + cleared by the display link.
nonisolated final class DirtyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty = false
    func set() { lock.lock(); dirty = true; lock.unlock() }
    func testAndClear() -> Bool { lock.lock(); defer { dirty = false; lock.unlock() }; return dirty }
}

/// Keeps a display copy of the library's framebuffer and refreshes it only when a whole update has
/// arrived, so a change appears at once instead of being drawn top to bottom as rectangles decode.
/// Called on the library's receive thread; the copy happens between updates, while nothing writes.
nonisolated final class FramePresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var back: IOSurface?
    private var front: IOSurface?
    private var pending: [(x: Int, y: Int, width: Int, height: Int)] = []
    private var pendingArea = 0

    /// A display copy of `surface` (the library's framebuffer), filled with its current contents.
    func attach(_ surface: IOSurface) -> IOSurface? {
        lock.lock(); defer { lock.unlock() }
        guard let copy = IOSurface(properties: [
            .width: surface.width, .height: surface.height,
            .bytesPerElement: surface.bytesPerElement, .bytesPerRow: surface.bytesPerRow,
            .pixelFormat: surface.pixelFormat,
        ]) else { return nil }
        back = surface
        front = copy
        pending = []
        pendingArea = 0
        Self.copy(x: 0, y: 0, width: surface.width, height: surface.height, from: surface, to: copy)
        return copy
    }

    /// The library decoded into this rectangle (framebuffer pixels); shown at the next `present()`.
    func markUpdated(x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        pending.append((x, y, width, height))
        pendingArea += width * height
    }

    /// Copies everything updated since the last call into the display copy. False if nothing was.
    @discardableResult
    func present() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let back, let front, !pending.isEmpty else { return false }
        let w = min(back.width, front.width), h = min(back.height, front.height)
        if pendingArea >= w * h {
            Self.copy(x: 0, y: 0, width: w, height: h, from: back, to: front)
        } else {
            for r in pending {
                let x = max(0, r.x), y = max(0, r.y)
                Self.copy(x: x, y: y, width: min(r.x + r.width, w) - x, height: min(r.y + r.height, h) - y,
                          from: back, to: front)
            }
        }
        pending.removeAll(keepingCapacity: true)
        pendingArea = 0
        return true
    }

    private static func copy(x: Int, y: Int, width: Int, height: Int, from source: IOSurface, to target: IOSurface) {
        guard width > 0, height > 0 else { return }
        source.lock(options: .readOnly, seed: nil)
        target.lock(options: [], seed: nil)
        defer {
            target.unlock(options: [], seed: nil)
            source.unlock(options: .readOnly, seed: nil)
        }
        let bytesPerPixel = source.bytesPerElement
        let sourceRow = source.bytesPerRow, targetRow = target.bytesPerRow
        if x == 0, width == source.width, sourceRow == targetRow {
            memcpy(target.baseAddress + y * targetRow, source.baseAddress + y * sourceRow, height * sourceRow)
            return
        }
        for row in y..<(y + height) {
            memcpy(target.baseAddress + row * targetRow + x * bytesPerPixel,
                   source.baseAddress + row * sourceRow + x * bytesPerPixel,
                   width * bytesPerPixel)
        }
    }
}

/// Why a gateway connection was turned down, when it was.
nonisolated enum GatewayIssue: Sendable, Equatable {
    case certificateMismatch, notPaired
}

/// RoyalVNCKit's delegate. Called on background threads (and synchronously on the caller's
/// thread for `.connecting` / user disconnects), so it is nonisolated and hops to the main actor
/// in FIFO order. Framebuffer updates do NOT hop: they're copied for display once complete, then
/// set the dirty flag.
nonisolated final class ConnectionBridge: NSObject, VNCConnectionDelegate, VNCConnectionClipboardDelegate,
                                          VNCConnectionFrameDelegate, @unchecked Sendable {
    struct Credentials: Sendable { let username: String; let password: String }

    private let credentials: Credentials?
    private let allowOtherAuth: Bool
    private let dirty: DirtyFlag
    private let presenter = FramePresenter()
    private let log: (@Sendable (String) -> Void)?
    /// Set when the PC asked for a kind of sign-in we won't answer.
    private let refusedAuth = OSAllocatedUnfairLock(initialState: false)
    /// Main-actor-only; touched inside main hops.
    nonisolated(unsafe) weak var session: VNCSession?

    init(session: VNCSession, credentials: Credentials?, allowOtherAuth: Bool = false, dirty: DirtyFlag,
         log: (@Sendable (String) -> Void)? = nil) {
        self.session = session
        self.credentials = credentials
        self.allowOtherAuth = allowOtherAuth
        self.dirty = dirty
        self.log = log
    }

    private func onMain(_ body: @escaping @MainActor (VNCSession, ConnectionBridge) -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard let session else { return }
                body(session, self)
            }
        }
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let error = connectionState.error
        let isAuth = (error as? VNCError)?.isAuthenticationError ?? false
        let message = error.map { ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0) }
        // No sign-in the app accepts was offered (e.g. only "None"): report it as refused, not a wrong password.
        var noAcceptedSignIn = false
        if case .authentication(.clientCouldNotDecideOnSecurityType)? = error as? VNCError { noAcceptedSignIn = true }
        let refused = refusedAuth.withLock { $0 } || noAcceptedSignIn
        var gatewayIssue: GatewayIssue?
        if case .connection(.gatewayCertificateMismatch)? = error as? VNCError { gatewayIssue = .certificateMismatch }
        if case .connection(.gatewayRejected)? = error as? VNCError { gatewayIssue = .notPaired }
        let name = ["disconnected", "connecting", "connected", "disconnecting"][min(status.rawValue, 3)]
        log?("state \(name) \(message ?? "")")
        onMain { session, bridge in
            session.bridge(bridge, didChange: status, authFailed: isAuth, authRefused: refused,
                           gatewayIssue: gatewayIssue, message: message)
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        log?("auth requested: \(authenticationType) requiresUsername=\(authenticationType.requiresUsername)")
        guard let credentials else { completion(nil); return }
        guard CredentialPolicy.mayAnswer(authenticationType, allowOutsideTailscale: allowOtherAuth) else {
            log?("auth refused: not a Windows VNC sign-in, password not sent")
            refusedAuth.withLock { $0 = true }
            completion(nil)
            return
        }
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: credentials.username, password: credentials.password))
        } else {
            completion(VNCPasswordCredential(password: credentials.password))
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        publish(framebuffer)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        publish(framebuffer)
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        presenter.markUpdated(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    }

    func connectionDidFinishFramebufferUpdate(_ connection: VNCConnection) {
        if presenter.present() { dirty.set() }
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        let image = cursor.isEmpty ? nil : cursor.cgImage
        let hotspot = cursor.cgHotspot
        let box = CursorBox(image: image, hotspot: hotspot, hidden: cursor.isEmpty)
        onMain { session, bridge in session.bridge(bridge, didUpdateCursor: box) }
    }

    func connection(_ connection: VNCConnection, didReceiveClipboardText text: String) {
        log?(text.isEmpty ? "clipboard message from PC (empty)" : "clipboard from PC: \(text.count) chars")
        onMain { session, bridge in session.bridge(bridge, didReceiveClipboard: text) }
    }

    private func publish(_ framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        log?("framebuffer \(Int(size.width))×\(Int(size.height))")
        guard let surface = framebuffer.ioSurface, let display = presenter.attach(surface) else { return }
        let box = SurfaceBox(surface: display, size: size)
        dirty.set()
        onMain { session, bridge in session.bridge(bridge, didSetFramebuffer: box) }
    }
}

nonisolated struct CursorBox: @unchecked Sendable {
    let image: CGImage?
    let hotspot: CGPoint
    let hidden: Bool
}
