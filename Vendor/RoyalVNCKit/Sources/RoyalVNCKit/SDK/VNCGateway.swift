// LOCAL PATCH: DuoPC Gateway support (see PATCHES.md, item 8).
//
// The gateway (windows/DuoPCGateway) is a TLS 1.3 front door to a VNC server that listens only on
// 127.0.0.1. The client pins the SHA-256 of the gateway's self-signed certificate instead of
// trusting a certificate authority, then proves it's a paired device with a 32-byte token:
//   client → gateway   "DPC1" + token
//   gateway → client   0x00 accepted (plain RFB follows, inside TLS) or 0x01 rejected (then closed)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Network)
import CryptoKit
import Network
import Security
#endif

public struct VNCGatewaySettings: Sendable, Equatable {
	/// SHA-256 of the gateway certificate's DER bytes.
	public let certificateSHA256: Data
	public let token: Data

	public init(certificateSHA256: Data, token: Data) {
		self.certificateSHA256 = certificateSHA256
		self.token = token
	}

	static let helloMagic = Data("DPC1".utf8)
	static let accepted: UInt8 = 0x00
	static let rejected: UInt8 = 0x01

	var hello: Data { Self.helloMagic + token }
}

/// Set by the TLS verify block when the server's certificate isn't the pinned one, so the failure
/// can be reported as that rather than as a generic TLS error.
final class VNCGatewayPinCheck: @unchecked Sendable {
	private let lock = NSLock()
	private var mismatched = false

	func recordMismatch() {
		lock.lock(); mismatched = true; lock.unlock()
	}

	var didMismatch: Bool {
		lock.lock(); defer { lock.unlock() }
		return mismatched
	}
}

#if canImport(Network)
public extension VNCGatewaySettings {
	/// TLS 1.3 that trusts exactly one certificate: the one whose DER bytes hash to `pin`. No certificate
	/// authority, name or expiry check applies; the pin is the whole check. Shared by the VNC connection
	/// and DuoPC's video stream.
	static func tlsOptions(pinning pin: Data, onMismatch: (@Sendable () -> Void)? = nil) -> NWProtocolTLS.Options {
		let options = NWProtocolTLS.Options()
		let security = options.securityProtocolOptions
		sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
		sec_protocol_options_set_verify_block(security, { _, trust, complete in
			let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
			let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
			let matches = leaf.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)) == pin } ?? false
			if !matches { onMismatch?() }
			complete(matches)
		}, DispatchQueue.global(qos: .userInitiated))
		return options
	}
}
#endif
