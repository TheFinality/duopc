#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public extension VNCError {
	enum ConnectionError: Error, LocalizedError {
		case notReady
		case closed
		case closedDuringHandshake(handshakingPhase: String, underlyingError: Error?)
		case cancelled
		case failed(_ underlyingError: Error?)
		// LOCAL PATCH: DuoPC Gateway. The server's certificate isn't the paired one.
		case gatewayCertificateMismatch
		// LOCAL PATCH: DuoPC Gateway. The gateway doesn't know this device's pairing token.
		case gatewayRejected

		// MARK: - LocalizedError
		public var errorDescription: String? {
			// TODO: Localize
			switch self {
				case .notReady:
					return "The Connection is not ready."
				case .closed:
					return "The Connection was closed."
				case .closedDuringHandshake(let handshakingPhase, let underlyingError):
					return VNCError.combinedErrorDescription("The Connection was closed during the \"\(handshakingPhase)\" handshaking phase.",
															 underlyingError: underlyingError)
				case .cancelled:
					return "The Connection was cancelled."
				case .failed(let underlyingError):
					return VNCError.combinedErrorDescription("The Connection failed.",
															 underlyingError: underlyingError)
				case .gatewayCertificateMismatch:
					return "The server's certificate isn't the one this device was paired with."
				case .gatewayRejected:
					return "The gateway didn't accept this device's pairing."
			}
		}
	}
}
