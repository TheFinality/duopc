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
        #expect(host.symbolName == "desktopcomputer")
        #expect(host.allowOutsideTailscale == false)
    }

    @Test func allowOutsideTailscaleRoundTrips() throws {
        var host = Host(name: "A", hostname: "a", username: "u")
        host.allowOutsideTailscale = true
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(back.allowOutsideTailscale)
    }

    @Test func newFieldsRoundTrip() throws {
        let host = Host(name: "A", hostname: "a", username: "u", symbol: "macmini",
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
}

private struct StubProbe: ReachabilityProbe {
    let online: Set<String>
    func isReachable(hostname: String, port: UInt16) async -> Bool { online.contains(hostname) }
}
