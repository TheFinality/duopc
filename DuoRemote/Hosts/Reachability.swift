import Foundation
import Network
import Observation

/// Checks whether a Mac accepts TCP connections. Behind a protocol so tests can stub it.
nonisolated protocol ReachabilityProbe: Sendable {
    func isReachable(hostname: String, port: UInt16) async -> Bool
}

nonisolated struct TCPReachabilityProbe: ReachabilityProbe {
    var timeout: Duration = .seconds(2)

    func isReachable(hostname: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(hostname), port: nwPort, using: .tcp)
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: continuation.yield(true); continuation.finish()
            case .failed, .cancelled: continuation.yield(false); continuation.finish()
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        let timeout = timeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(false)
            continuation.finish()
        }
        defer {
            timer.cancel()
            connection.cancel()
            continuation.finish()
        }
        for await result in stream { return result }
        return false   // cancelled
    }
}

enum ReachabilityState: Equatable {
    case checking, online, offline
}

/// Per-host status for the hosts screen.
@Observable
final class ReachabilityModel {
    private(set) var states: [UUID: ReachabilityState] = [:]
    @ObservationIgnored private let probe: any ReachabilityProbe
    @ObservationIgnored private var task: Task<Void, Never>?

    init(probe: any ReachabilityProbe = TCPReachabilityProbe()) {
        self.probe = probe
    }

    func state(for host: Host) -> ReachabilityState { states[host.id] ?? .checking }

    /// Probes every host concurrently, cancelling any run in flight.
    @discardableResult
    func refresh(_ hosts: [Host]) -> Task<Void, Never> {
        task?.cancel()
        for host in hosts { states[host.id] = .checking }
        let probe = probe
        let new = Task { [weak self] in
            await withTaskGroup(of: (UUID, Bool).self) { group in
                for host in hosts {
                    group.addTask { (host.id, await probe.isReachable(hostname: host.hostname, port: host.port)) }
                }
                for await (id, ok) in group {
                    if Task.isCancelled { return }
                    self?.states[id] = ok ? .online : .offline
                }
            }
        }
        task = new
        return new
    }

    func cancel() { task?.cancel() }
}
