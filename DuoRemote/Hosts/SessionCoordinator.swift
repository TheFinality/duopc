import SwiftUI
import UIKit
import Observation

/// Reconnect backoff, kept pure so it can be tested.
enum RetryPolicy {
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Delay before retry number `attempt` (1-based). `nil` once retries are exhausted.
    static func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }

    /// Whether a failure is worth retrying automatically.
    static func shouldRetry(_ failure: VNCSession.Failure?) -> Bool {
        switch failure {
        case .network, .closedByServer: true
        case .authenticationFailed, .outsideTailscale, .insecureAuthentication, nil: false
        }
    }
}

/// Owns the active session and its lifecycle (connect, credentials, background, reconnect).
@Observable
final class SessionCoordinator {
    let store: HostStore
    private(set) var active: VNCSession?
    private(set) var activeHost: Host?
    /// Non-nil → the shell presents `CredentialSheet` for this host.
    var credentialPrompt: Host?
    /// Set with `credentialPrompt` when the Mac isn't reached through Tailscale: the address it
    /// resolved to, so the sheet can warn before a password is sent there.
    private(set) var outsideTailscaleAddress: String?
    /// The Mac whose address is being looked up and checked, before anything is sent to it.
    private(set) var lookingUpHostID: UUID?

    private struct Credentials {
        var username: String
        var password: String
        /// An address outside Tailscale the user chose to send these to.
        var approvedAddress: String?
    }

    // Everything below is bookkeeping, not UI state.
    @ObservationIgnored private var sessions: [UUID: VNCSession] = [:]
    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var phase: ScenePhase = .active
    @ObservationIgnored private var resumeHost: Host?
    @ObservationIgnored private var observationGeneration = 0

    init(store: HostStore) {
        self.store = store
    }

    // MARK: Connecting

    /// Connects using the saved username + Keychain password, or asks for them.
    func connect(_ host: Host) {
        retryAttempt = 0
        startConnect(host, given: nil)
    }

    /// Connects with credentials just entered (which may not be saved).
    /// - Parameter approvedAddress: an address outside Tailscale the user agreed to send them to.
    func connect(_ host: Host, username: String, password: String, approvedAddress: String? = nil) {
        retryAttempt = 0
        startConnect(host, given: Credentials(username: username, password: password, approvedAddress: approvedAddress))
    }

    /// Manual retry from the shell's disconnected overlay. Resets the backoff.
    func retry() {
        guard let host = activeHost else { return }
        retryAttempt = 0
        resumeHost = nil
        startConnect(host, given: credentials)
    }

    /// Sets (or clears, with nil) the active Mac's scroll speed: applies now and is remembered.
    func setScrollSpeed(_ speed: Double?) {
        active?.scrollSpeedOverride = speed
        guard var host = activeHost.flatMap({ store.host(withID: $0.id) }) else { return }
        host.scrollSpeed = speed
        store.update(host)
        activeHost = host
    }

    /// User-initiated disconnect.
    func disconnect() {
        cancelTasks()
        observationGeneration += 1
        resumeHost = nil
        credentials = nil
        active?.disconnect()
        // Drop the cached session: it holds the full-resolution framebuffer.
        if let id = activeHost?.id { sessions[id] = nil }
        active = nil
        activeHost = nil
        updateIdleTimer()
    }

    /// Every connect, retry and reconnect comes through here, so each one re-checks the route
    /// before a password goes out.
    private func startConnect(_ requested: Host, given: Credentials?) {
        cancelTasks()
        let host = store.host(withID: requested.id) ?? requested
        lookingUpHostID = host.id
        connectTask = Task {
            defer { if !Task.isCancelled { lookingUpHostID = nil } }
            let route = await Tailnet.route(to: host.hostname, port: host.port)
            guard !Task.isCancelled else { return }
            var resolved = given
            if resolved == nil, !host.username.isEmpty {
                let saved = try? await store.keychain.password(forHostID: host.id)
                if let password = saved ?? nil, !password.isEmpty {
                    resolved = Credentials(username: host.username, password: password)
                }
            }
            guard !Task.isCancelled else { return }
            let outside: String? = if case .outside(let address) = route { address } else { nil }
            guard let resolved else {
                prompt(host, outsideAddress: outside)
                return
            }
            if CredentialPolicy.maySend(over: route, allowOutsideTailscale: host.allowOutsideTailscale,
                                        approvedAddress: resolved.approvedAddress) {
                begin(host, credentials: resolved, address: route.address)
            } else if route == .unresolved {
                begin(host, credentials: resolved, address: nil,
                      blocked: .network("Can't find \(host.hostname). Is Tailscale connected?"))
            } else {
                if activeHost?.id == host.id { active?.block(.outsideTailscale) }
                credentials = nil
                prompt(host, outsideAddress: outside)
            }
        }
    }

    private func prompt(_ host: Host, outsideAddress: String?) {
        outsideTailscaleAddress = outsideAddress
        credentialPrompt = host
    }

    /// - Parameters:
    ///   - address: the checked address to connect to (nil = let the library resolve the name).
    ///   - blocked: show this failure instead of connecting.
    private func begin(_ host: Host, credentials: Credentials, address: String?, blocked: VNCSession.Failure? = nil) {
        if let current = active, activeHost?.id != host.id { current.disconnect() }

        let session: VNCSession
        if let existing = sessions[host.id], existing.hostname == host.hostname, existing.port == host.port {
            session = existing
        } else {
            session = VNCSession(hostname: host.hostname, port: host.port)
            sessions[host.id] = session
        }
        session.scrollSpeedOverride = store.host(withID: host.id)?.scrollSpeed ?? host.scrollSpeed

        self.credentials = credentials
        resumeHost = nil
        activeHost = host
        active = session
        observe(session)

        if let blocked {
            session.block(blocked)
        } else {
            switch session.status {
            case .connecting, .connected: break
            default:
                session.connect(username: credentials.username, password: credentials.password,
                                address: address, allowOtherAuth: host.allowOutsideTailscale)
            }
        }
        updateIdleTimer()
    }

    // MARK: Status observation

    private func observe(_ session: VNCSession) {
        observationGeneration += 1
        arm(session, generation: observationGeneration)
    }

    /// `withObservationTracking` fires once, so each change re-arms. A stale generation ends the chain.
    private func arm(_ session: VNCSession, generation: Int) {
        withObservationTracking {
            _ = session.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation, self.active === session else { return }
                self.statusChanged(session.status)
                self.arm(session, generation: generation)
            }
        }
    }

    private func statusChanged(_ status: VNCSession.Status) {
        updateIdleTimer()
        // We disconnect on purpose when backgrounding; don't react to that.
        guard resumeHost == nil else { return }
        switch status {
        case .connected:
            if let id = activeHost?.id, var saved = store.host(withID: id) {
                saved.lastConnected = Date()
                store.update(saved)
            }
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
        case .disconnected(.authenticationFailed?):
            retryTask?.cancel()
            retryTask = nil
            credentials = nil
            if let host = activeHost { prompt(host, outsideAddress: nil) }
        case .disconnected(let failure) where RetryPolicy.shouldRetry(failure):
            scheduleRetry()
        default:
            break
        }
    }

    private func scheduleRetry() {
        guard phase == .active else { return }
        retryAttempt += 1
        guard let delay = RetryPolicy.delay(forAttempt: retryAttempt) else { return }
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, phase == .active, active != nil, let host = activeHost, let credentials else { return }
            retryTask = nil
            startConnect(host, given: credentials)
        }
    }

    // MARK: Scene lifecycle

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        phase = newPhase
        switch newPhase {
        case .background:
            retryTask?.cancel()
            retryTask = nil
            guard let session = active, !session.isDemo, let host = activeHost else { break }
            switch session.status {
            case .connected, .connecting, .disconnected(.network?), .disconnected(.closedByServer?):
                resumeHost = host
                let app = UIApplication.shared
                let task = app.beginBackgroundTask(withName: "vnc-disconnect")
                session.disconnect()
                if task != .invalid { app.endBackgroundTask(task) }
            default:
                break
            }
        case .active:
            if let host = resumeHost {
                resumeHost = nil
                retryAttempt = 0
                startConnect(host, given: credentials)
            }
        default:
            break
        }
        updateIdleTimer()
    }

    // MARK: Helpers

    private func cancelTasks() {
        connectTask?.cancel()
        connectTask = nil
        lookingUpHostID = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = active?.status == .connected
    }

    /// Opens a demo session: a built-in test pattern, no network. Lets anyone try the controls
    /// before setting up a Mac.
    func openDemo() {
        activeHost = Host(name: "Demo", hostname: "demo", username: "")
        active = .demo()
        updateIdleTimer()
    }
}
