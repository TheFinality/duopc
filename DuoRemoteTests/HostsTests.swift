import Testing
import Foundation
@testable import DuoRemote

@MainActor
struct HostsTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hosts-\(UUID().uuidString).json")
    }

    @Test func firstLaunchStartsEmpty() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostStore(fileURL: url)
        #expect(store.hosts.isEmpty)
    }

    @Test func emptyListStaysEmpty() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = HostStore(fileURL: url)
        first.add(Host(name: "A", hostname: "a", username: "u"))
        for host in first.hosts { first.delete(host) }
        #expect(first.hosts.isEmpty)

        let second = HostStore(fileURL: url)
        #expect(second.hosts.isEmpty)
    }

    @Test func roundTripThroughFile() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostStore(fileURL: url)
        var extra = Host(name: "Studio", hostname: "studio", port: 5901, username: "user")
        store.add(extra)
        extra.username = "other"
        store.update(extra)

        let reloaded = HostStore(fileURL: url)
        #expect(reloaded.hosts == store.hosts)
        #expect(reloaded.host(withID: extra.id)?.username == "other")
        #expect(reloaded.host(withID: extra.id)?.port == 5901)
    }

    @Test func retryBackoffIsOneTwoFourThenStops() {
        #expect(RetryPolicy.delay(forAttempt: 1) == .seconds(1))
        #expect(RetryPolicy.delay(forAttempt: 2) == .seconds(2))
        #expect(RetryPolicy.delay(forAttempt: 3) == .seconds(4))
        #expect(RetryPolicy.delay(forAttempt: 4) == nil)
        #expect(RetryPolicy.delay(forAttempt: 0) == nil)
    }

    @Test func onlyNetworkAndServerCloseRetry() {
        #expect(RetryPolicy.shouldRetry(.network("x")))
        #expect(RetryPolicy.shouldRetry(.closedByServer))
        #expect(!RetryPolicy.shouldRetry(.authenticationFailed))
        #expect(!RetryPolicy.shouldRetry(nil))
    }

    @Test func oldJSONDecodesWithoutNewFields() throws {
        let json = #"{"id":"6E1C3E5A-2C1B-4B8E-9A55-0F4E4B1E7A11","name":"Mini","hostname":"mini","port":5901,"username":"me"}"#
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.name == "Mini" && host.port == 5901 && host.username == "me")
        #expect(host.symbol == nil && host.lastConnected == nil)
        #expect(host.symbolName == "pc")
        #expect(host.allowOutsideTailscale == false)
    }

    @Test func allowOutsideTailscaleRoundTrips() throws {
        var host = Host(name: "A", hostname: "a", username: "u")
        host.allowOutsideTailscale = true
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(back.allowOutsideTailscale)
    }

    @Test func newFieldsRoundTrip() throws {
        let host = Host(name: "A", hostname: "a", username: "u", symbol: "laptopcomputer",
                        lastConnected: Date(timeIntervalSince1970: 100))
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(back == host)
    }

    @Test func reachabilityStatesFollowProbe() async {
        let up = Host(name: "Up", hostname: "up", username: "")
        let down = Host(name: "Down", hostname: "down", username: "")
        let model = ReachabilityModel(probe: StubProbe(online: ["up"]))
        #expect(model.state(for: up) == .checking)
        let run = model.refresh([up, down])
        #expect(model.state(for: up) == .checking)
        await run.value
        #expect(model.state(for: up) == .online)
        #expect(model.state(for: down) == .offline)
    }

    // MARK: Pairing codes (as made by windows/DuoPCGateway)

    static let fingerprint = "4fd836035c3685bb93dac915c29909905d399dbc59bc41a564d89b3badefb172"
    static let token = Data((0..<32).map { UInt8($0) })
    static func code(_ extra: String = "") -> String {
        "duopc://pair?v=1&n=DESKTOP-1&h=myhome.example.net&p=5960&fp=\(fingerprint)&t=\(base64URL(token))" + extra
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func pairingCodeParses() throws {
        let code = try #require(PairingCode.parse(Self.code("&pw=p%40ss%20w0rd")))
        #expect(code.name == "DESKTOP-1" && code.hostname == "myhome.example.net" && code.port == 5960)
        #expect(code.certificateSHA256 == Self.fingerprint)
        #expect(code.token == Self.token)
        #expect(code.vncPassword == "p@ss w0rd")
        #expect(PairingCode.parse("  " + Self.code() + "\n")?.vncPassword == nil)
    }

    @Test func malformedPairingCodesAreRefused() {
        let fp = Self.fingerprint, t = Self.base64URL(Self.token)
        #expect(PairingCode.parse("https://pair?v=1&h=a&p=1&fp=\(fp)&t=\(t)") == nil)        // wrong scheme
        #expect(PairingCode.parse("duopc://pair?v=2&h=a&p=1&fp=\(fp)&t=\(t)") == nil)        // unknown version
        #expect(PairingCode.parse("duopc://pair?v=1&h=&p=1&fp=\(fp)&t=\(t)") == nil)         // no host
        #expect(PairingCode.parse("duopc://pair?v=1&h=a&p=0&fp=\(fp)&t=\(t)") == nil)        // bad port
        #expect(PairingCode.parse("duopc://pair?v=1&h=a&p=1&fp=\(fp.dropLast())&t=\(t)") == nil)  // short pin
        #expect(PairingCode.parse("duopc://pair?v=1&h=a&p=1&fp=\(fp)&t=AAAA") == nil)         // short token
        #expect(PairingCode.parse("duopc://pair?v=1&h=a&p=1&fp=\(String(repeating: "z", count: 64))&t=\(t)") == nil)
        #expect(PairingCode.parse("duopc://pair?v=1&h=a&p=1&fp=\(fp)&t=\(t)&pw=\(String(repeating: "x", count: 64))") == nil)
        #expect(PairingCode.parse("hello") == nil)
    }

    @Test func pairedHostKeepsItsPin() throws {
        var host = Host(name: "PC", hostname: "myhome.example.net", port: 5960, username: "")
        #expect(!host.isDirect && host.gatewayPin == nil)
        host.gatewayCertificateSHA256 = Self.fingerprint
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(back.isDirect && back.gatewayPin?.count == 32)
        #expect(PairingCode.shortFingerprint(Self.fingerprint) == "4fd8 3603 5c36 85bb")
    }

    @Test func pairedPCsUseVideoUnlessTurnedOff() {
        var host = Host(name: "PC", hostname: "myhome.example.net", port: 5960, username: "")
        #expect(!host.usesVideo)                     // not paired: VNC
        host.gatewayCertificateSHA256 = Self.fingerprint
        #expect(host.usesVideo)                      // paired: video by default
        host.videoStreaming = false
        #expect(!host.usesVideo)
    }
}

private struct StubProbe: ReachabilityProbe {
    let online: Set<String>
    func isReachable(hostname: String, port: UInt16) async -> Bool { online.contains(hostname) }
}
