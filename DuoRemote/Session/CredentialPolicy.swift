@preconcurrency import RoyalVNCKit
import Darwin
import Foundation

/// How a Mac's hostname is reached, checked before a password is sent to it.
nonisolated enum TailnetRoute: Equatable, Sendable {
    /// Every address is a Tailscale address that leaves through the Tailscale tunnel. Connect to this one.
    case tailnet(String)
    /// Reached some other way (the first such address).
    case outside(String)
    /// The name didn't resolve.
    case unresolved

    var address: String? {
        switch self {
        case .tailnet(let a), .outside(let a): a
        case .unresolved: nil
        }
    }
}

/// When the app may send a password. Pure, so it can be tested.
nonisolated enum CredentialPolicy {
    /// A password goes out only over Tailscale, unless the host allows otherwise or the user
    /// approved this exact address.
    static func maySend(over route: TailnetRoute, allowOutsideTailscale: Bool, approvedAddress: String?) -> Bool {
        switch route {
        case .tailnet: true
        case .outside(let address): allowOutsideTailscale || address == approvedAddress
        case .unresolved: allowOutsideTailscale
        }
    }

    /// Only a macOS sign-in (ARD) gets the password, unless the host allows other kinds.
    static func mayAnswer(_ type: VNCAuthenticationType, allowOutsideTailscale: Bool) -> Bool {
        type == .appleRemoteDesktop || allowOutsideTailscale
    }
}

nonisolated enum Tailnet {
    /// One resolved address and the local source address and interface the system would use for it.
    struct Path: Equatable, Sendable {
        let remote: String
        let local: String?
        let interface: String?
    }

    /// 100.64.0.0/10 or fd7a:115c:a1e0::/48 (or an IPv4-mapped form of the former).
    static func isTailscaleAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let b = withUnsafeBytes(of: v4) { Array($0) }
            return isTailscaleV4(b[0], b[1])
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return isTailscaleV4(b[12], b[13]) }
        return b[0..<6].elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    private static func isTailscaleV4(_ a: UInt8, _ b: UInt8) -> Bool { a == 100 && b & 0xC0 == 64 }

    /// A 64:ff9b::/96 NAT64 address and the IPv4 address it wraps.
    static func nat64Embedded(_ address: String) -> String? {
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        guard b[0..<12].elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) else { return nil }
        return "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
    }

    /// Tailscale only if every path goes to a Tailscale address from a Tailscale address on a
    /// tunnel interface: a hostile network can answer DNS with 100.x and route it itself.
    static func decide(_ paths: [Path]) -> TailnetRoute {
        let remotes = Set(paths.map(\.remote))
        // An IPv6-only network may add NAT64 copies of the IPv4 answers; the IPv4 ones decide.
        let paths = paths.filter { nat64Embedded($0.remote).map { !remotes.contains($0) } ?? true }
        guard !paths.isEmpty else { return .unresolved }
        if let outside = paths.first(where: { !isTailnetPath($0) }) { return .outside(outside.remote) }
        let pick = paths.first { !$0.remote.contains(":") } ?? paths[0]
        return .tailnet(pick.remote)
    }

    static func isTailnetPath(_ p: Path) -> Bool {
        guard isTailscaleAddress(p.remote), let local = p.local, isTailscaleAddress(local) else { return false }
        return p.interface?.hasPrefix("utun") == true
    }

    /// Resolves `hostname` (blocking work, off the main actor) and decides how it's reached.
    static func route(to hostname: String, port: UInt16) async -> TailnetRoute {
        await Task.detached(priority: .userInitiated) { decide(paths(for: hostname, port: port)) }.value
    }

    private static func paths(for hostname: String, port: UInt16) -> [Path] {
        let name = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, String(port), &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }

        let interfaces = interfaceNames()
        var seen = Set<String>()
        var result: [Path] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = info.pointee.ai_addr, let remote = numericHost(addr, info.pointee.ai_addrlen),
                  seen.insert(remote).inserted else { continue }
            let local = sourceAddress(toward: addr, length: info.pointee.ai_addrlen, family: info.pointee.ai_family)
            result.append(Path(remote: remote, local: local, interface: local.flatMap { interfaces[$0] }))
        }
        return result
    }

    /// The local address the routing table picks for `addr`. A connected UDP socket sends nothing.
    private static func sourceAddress(toward addr: UnsafePointer<sockaddr>, length: socklen_t, family: Int32) -> String? {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, addr, length) == 0 else { return nil }
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        return withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &size) == 0 ? numericHost(sa, size) : nil
            }
        }
    }

    /// Local address → interface name (e.g. "utun4").
    private static func interfaceNames() -> [String: String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(first) }
        var names: [String: String] = [:]
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            if let host = numericHost(addr, length) { names[host] = String(cString: ifa.pointee.ifa_name) }
        }
        return names
    }

    private static func numericHost(_ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
