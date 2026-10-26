@preconcurrency import RoyalVNCKit
import CoreGraphics
import Foundation
import IOSurface
import os

/// A framebuffer's IOSurface handed across threads. The library keeps writing into it; we only
/// sample it on the GPU, so sharing is the point.
nonisolated struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
    let size: CGSize
}

/// Set from the library's threads on every framebuffer rect, read + cleared by the display link.
nonisolated final class DirtyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty = false
    func set() { lock.lock(); dirty = true; lock.unlock() }
    func testAndClear() -> Bool { lock.lock(); defer { dirty = false; lock.unlock() }; return dirty }
}

/// RoyalVNCKit's delegate. Called on background threads (and synchronously on the caller's
/// thread for `.connecting` / user disconnects), so it is nonisolated and hops to the main actor
/// in FIFO order. Framebuffer rect updates do NOT hop: they only set the dirty flag.
nonisolated final class ConnectionBridge: NSObject, VNCConnectionDelegate, VNCConnectionClipboardDelegate, @unchecked Sendable {
    struct Credentials: Sendable { let username: String; let password: String }

    private let credentials: Credentials?
    private let allowOtherAuth: Bool
    private let dirty: DirtyFlag
    private let log: (@Sendable (String) -> Void)?
    /// Set when the Mac asked for a kind of sign-in we won't answer.
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
        let name = ["disconnected", "connecting", "connected", "disconnecting"][min(status.rawValue, 3)]
        log?("state \(name) \(message ?? "")")
        onMain { session, bridge in
            session.bridge(bridge, didChange: status, authFailed: isAuth, authRefused: refused, message: message)
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        log?("auth requested: \(authenticationType) requiresUsername=\(authenticationType.requiresUsername)")
        guard let credentials else { completion(nil); return }
        guard CredentialPolicy.mayAnswer(authenticationType, allowOutsideTailscale: allowOtherAuth) else {
            log?("auth refused: not a macOS sign-in, password not sent")
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
        dirty.set()
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        let image = cursor.isEmpty ? nil : cursor.cgImage
        let hotspot = cursor.cgHotspot
        let box = CursorBox(image: image, hotspot: hotspot, hidden: cursor.isEmpty)
        onMain { session, bridge in session.bridge(bridge, didUpdateCursor: box) }
    }

    func connection(_ connection: VNCConnection, didReceiveClipboardText text: String) {
        log?(text.isEmpty ? "clipboard message from Mac (empty)" : "clipboard from Mac: \(text.count) chars")
        onMain { session, bridge in session.bridge(bridge, didReceiveClipboard: text) }
    }

    private func publish(_ framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        log?("framebuffer \(Int(size.width))×\(Int(size.height))")
        guard let surface = framebuffer.ioSurface else { return }
        let box = SurfaceBox(surface: surface, size: size)
        dirty.set()
        onMain { session, bridge in session.bridge(bridge, didSetFramebuffer: box) }
    }
}

nonisolated struct CursorBox: @unchecked Sendable {
    let image: CGImage?
    let hotspot: CGPoint
    let hidden: Bool
}
