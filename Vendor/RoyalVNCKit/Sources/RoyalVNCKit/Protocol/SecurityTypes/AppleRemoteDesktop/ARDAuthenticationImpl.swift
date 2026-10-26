#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Security)
import Security
#endif

extension VNCProtocol.ARDAuthentication {
    struct Authentication {
        let cipherText: Data
        let publicKey: Data

        private init(cipherText: Data,
                     publicKey: Data) {
            self.cipherText = cipherText
            self.publicKey = publicKey
        }

        init?(agreement: DiffieHellmanKeyAgreement,
              username: String,
              password: String) {
            // Get MD5 hash of shared secret
			let secretHash = agreement.secretKey.md5Hash()

            // ciphertext: AES128(shared, username[64]:password[64])
            let credArraySize = 128
            var creds = Data(count: credArraySize)

            let randomCredsDataSuccess = creds.withUnsafeMutableBytes {
                guard let credsBytes = $0.baseAddress else { return false }

#if canImport(Security)
				let randomStatus = SecRandomCopyBytes(kSecRandomDefault, credArraySize, credsBytes)

                guard randomStatus == errSecSuccess else { return false }
#else
				// TODO: Probably not secure
				for i in 0..<credArraySize {
					$0[i] = UInt8.random(in: 0...255)
				}
#endif

                return true
            }

            guard randomCredsDataSuccess else { return nil }

			// LOCAL PATCH: cap at 63 UTF-8 bytes (was 63 characters, which wrote past the 64-byte
			// fields for multi-byte text, or indexed past the end of a short multi-byte string).
			let cappedUsername = VNCCredentialLimit.truncated(username)
			let cappedUsernameLength = cappedUsername.utf8.count

			let cappedPassword = VNCCredentialLimit.truncated(password)
			let cappedPasswordLength = cappedPassword.utf8.count

			guard cappedUsernameLength < credArraySize / 2, cappedPasswordLength < credArraySize / 2 else { return nil }

            // Convert username and password strings into C strings
            let usernameC = cappedUsername.utf8CString
            let passwordC = cappedPassword.utf8CString

			// Merge username and password into single array
			let fillCredsSuccess = creds.withUnsafeMutableBytes {
				guard let credsBytes = $0.baseAddress else { return false }

				let copyUsernameSuccess = usernameC.withUnsafeBytes { usernameCBytesPtr in
					guard let usernameCBytes = usernameCBytesPtr.baseAddress else { return false }

					credsBytes.copyMemory(from: usernameCBytes,
										  byteCount: cappedUsernameLength)

					return true
				}

				guard copyUsernameSuccess else { return false }

				let copyPasswordSuccess = passwordC.withUnsafeBytes { passwordCBytesPtr in
					guard let passwordCBytes = passwordCBytesPtr.baseAddress else { return false }

					let credsBytesStartingAtPassword = credsBytes.advanced(by: credArraySize / 2)

					credsBytesStartingAtPassword.copyMemory(from: passwordCBytes,
															byteCount: cappedPasswordLength)

					return true
				}

				guard copyPasswordSuccess else { return false }

				return true
			}

			guard fillCredsSuccess else { return nil }

			// Add null bytes to indicate end of c string
			creds[cappedUsernameLength] = 0
			creds[(credArraySize / 2) + cappedPasswordLength] = 0

			guard let cipherText = creds.aes128ECBEncrypted(withKey: secretHash) else {
				return nil
			}

            self.init(cipherText: cipherText,
                      publicKey: agreement.publicKey)
        }
    }
}
