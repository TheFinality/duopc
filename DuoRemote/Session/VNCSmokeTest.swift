#if DEBUG
import Foundation

/// `-vncSmoke <host>`: connect with no credentials and log state changes plus the requested auth
/// type as `[smoke]` lines on stdout. Proves tailnet + RFB handshake + auth negotiation without a
/// password (the connection then fails with "no authentication data", as expected).
enum VNCSmokeTest {
    private static var session: VNCSession?

    static func run(host: String) {
        let log: @Sendable (String) -> Void = { line in
            print("[smoke] \(line)")
            fflush(stdout)
        }
        log("connecting to \(host):5900")
        let s = VNCSession(hostname: host)
        session = s
        s.connect(credentials: nil, log: log)
    }
}
#endif
