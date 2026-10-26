#if canImport(Network)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CryptoKit
import Dispatch
import Network
import Security

extension NWConnection: NetworkConnection {
    convenience init(settings: NetworkConnectionSettings) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = settings.connectionTimeout

        // LOCAL PATCH: DuoPC Gateway connections are TLS 1.3, pinned to the paired certificate.
        let tlsOptions = settings.gateway.map { NWConnection.gatewayTLSOptions(pinning: $0.certificateSHA256,
                                                                               check: settings.gatewayPinCheck) }
        let connectionParameters = NWParameters(tls: tlsOptions,
                                                tcp: tcpOptions)

        connectionParameters.expiredDNSBehavior = .allow
        connectionParameters.serviceClass = .interactiveVideo

        self.init(host: .init(settings.host),
                  port: .init(rawValue: settings.port)!,
                  using: connectionParameters)
    }

    /// Trusts exactly one certificate: the one whose DER bytes hash to `pin`. No certificate
    /// authority, name or expiry check applies; the pin is the whole check.
    static func gatewayTLSOptions(pinning pin: Data, check: VNCGatewayPinCheck?) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
            let matches = leaf.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)) == pin } ?? false
            if !matches { check?.recordMismatch() }
            complete(matches)
        }, DispatchQueue.global(qos: .userInitiated))
        return options
    }

    var status: NetworkConnectionStatus {
        switch state {
        case .setup: .setup
        case .waiting(let error): .waiting(error)
        case .preparing: .preparing
        case .ready: .ready
        case .failed(let error): .failed(error)
        case .cancelled: .cancelled

        @unknown default:
            .unknown(self)
        }
    }

    func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
        guard let statusUpdateHandler else {
            stateUpdateHandler = nil

            return
        }

        stateUpdateHandler = { state in
            switch state {
            case .setup:
                statusUpdateHandler(.setup)
            case .waiting(let error):
                statusUpdateHandler(.waiting(error))
            case .preparing:
                statusUpdateHandler(.preparing)
            case .ready:
                statusUpdateHandler(.ready)
            case .failed(let error):
                statusUpdateHandler(.failed(error))
            case .cancelled:
                statusUpdateHandler(.cancelled)

            @unknown default:
                statusUpdateHandler(.unknown(self))
            }
        }
    }

    var isReady: Bool {
        state == .ready
    }
}

extension NWConnection: NetworkConnectionReading {
	func read(minimumLength: Int,
              maximumLength: Int) async throws -> Data {
		return try await withCheckedThrowingContinuation { continuation in
			receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { content, _, isComplete, error in
				guard !isComplete else {
					continuation.resume(throwing: VNCError.connection(.closed))

					return
				}

				guard error == nil else {
					continuation.resume(throwing: error!)

					return
				}

				guard let content else {
					continuation.resume(throwing: VNCError.protocol(.noData))

					return
				}

				let receivedLength = content.count

				guard receivedLength >= minimumLength,
					  receivedLength <= maximumLength else {
					continuation.resume(throwing: VNCError.protocol(.invalidData))

					return
				}

				continuation.resume(returning: content)
			}
		}
	}
}

extension NWConnection: NetworkConnectionWriting {
	func write(data: Data) async throws {
		return try await withCheckedThrowingContinuation { continuation in
			send(content: data, completion: .contentProcessed({ error in
				if let error = error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}))
		}
	}
}
#endif
