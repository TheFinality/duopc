import Foundation

/// A saved PC. The password lives in the Keychain, never here.
struct Host: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var hostname: String          // tailnet name, e.g. "my-pc"
    var port: UInt16 = 5900
    /// Only for a Windows-account sign-in (UltraVNC MS-Logon II); a VNC password needs none.
    var username: String
    /// SF Symbol name; see `HostSymbol`. nil means `pc`.
    var symbol: String?
    var lastConnected: Date?
    /// Per-PC scroll speed; nil = use the global default (Settings).
    var scrollSpeed: Double?
    /// Send the password even when the PC isn't reached through Tailscale, or asks for a kind of
    /// sign-in a Windows VNC server doesn't use (or none).
    var allowOutsideTailscale = false
    /// SHA-256 (hex) of the DuoPC Gateway's certificate. Set = a direct connection through the
    /// gateway: TLS 1.3 pinned to this certificate, from any network. nil = plain VNC, which sends
    /// the password only over Tailscale. The pairing token is in the Keychain.
    var gatewayCertificateSHA256: String?

    var isDirect: Bool { gatewayCertificateSHA256 != nil }
    var gatewayPin: Data? { gatewayCertificateSHA256.flatMap(PairingCode.hexData) }

    init(id: UUID = UUID(), name: String, hostname: String, port: UInt16 = 5900, username: String,
         symbol: String? = nil, lastConnected: Date? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.symbol = symbol
        self.lastConnected = lastConnected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 5900
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed)
        allowOutsideTailscale = try c.decodeIfPresent(Bool.self, forKey: .allowOutsideTailscale) ?? false
        gatewayCertificateSHA256 = try c.decodeIfPresent(String.self, forKey: .gatewayCertificateSHA256)
    }

    var symbolName: String { symbol ?? HostSymbol.defaultName }
}

/// The PC icons offered in the editor.
enum HostSymbol {
    static let defaultName = "pc"
    static let all = ["pc", "laptopcomputer", "desktopcomputer", "display", "server.rack"]

    static func label(_ name: String) -> String {
        switch name {
        case "laptopcomputer": "Laptop"
        case "desktopcomputer": "All-in-one"
        case "display": "Monitor"
        case "server.rack": "Server"
        default: "Desktop PC"
        }
    }
}

/// What DuoPC Gateway's pairing QR code holds (made by `DuoPCGateway pair`, windows/DuoPCGateway/Pairing.cs):
/// duopc://pair?v=1&n=NAME&h=HOST&p=PORT&fp=CERT_SHA256_HEX&t=TOKEN_BASE64URL[&pw=VNC_PASSWORD]
nonisolated struct PairingCode: Equatable, Sendable {
    var name: String
    var hostname: String
    var port: UInt16
    /// 64 lowercase hex digits.
    var certificateSHA256: String
    /// 32 bytes.
    var token: Data
    var vncPassword: String?

    /// nil for anything that isn't a complete, well-formed pairing code.
    static func parse(_ text: String) -> PairingCode? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "duopc", components.host?.lowercased() == "pair" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { if let value = item.value { query[item.name] = value } }
        guard query["v"] == "1",
              let hostname = query["h"]?.trimmingCharacters(in: .whitespaces), !hostname.isEmpty,
              let port = query["p"].flatMap({ UInt16($0) }), port > 0,
              let fingerprint = query["fp"]?.lowercased(), fingerprint.count == 64, hexData(fingerprint) != nil,
              let token = query["t"].flatMap(base64URLDecoded), token.count == 32 else { return nil }
        let password = query["pw"].flatMap { $0.isEmpty ? nil : $0 }
        // The same 63-byte cap as VNCCredentialLimit.
        if let password, password.utf8.count > 63 { return nil }
        let name = query["n"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return PairingCode(name: name.isEmpty ? hostname : name, hostname: hostname, port: port,
                           certificateSHA256: fingerprint, token: token, vncPassword: password)
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// The start of the fingerprint, grouped, for showing (e.g. "4fd8 3603 5c36 85bb").
    static func shortFingerprint(_ hex: String) -> String {
        stride(from: 0, to: min(hex.count, 16), by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}
