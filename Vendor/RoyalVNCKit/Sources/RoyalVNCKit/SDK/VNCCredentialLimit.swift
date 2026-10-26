import Foundation

// LOCAL PATCH: the ARD sign-in packs the username and password into two 64-byte C strings, so
// each is limited to 63 UTF-8 bytes. Truncate by bytes, never splitting a character.
public enum VNCCredentialLimit {
	public static let maxUTF8Bytes = 63

	public static func truncated(_ string: String, maxBytes: Int = maxUTF8Bytes) -> String {
		var result = ""
		var count = 0
		for character in string {
			let bytes = String(character).utf8.count
			guard count + bytes <= maxBytes else { break }
			result.append(character)
			count += bytes
		}
		return result
	}

	public static func fits(_ string: String) -> Bool { string.utf8.count <= maxUTF8Bytes }
}
