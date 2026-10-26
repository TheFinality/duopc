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
