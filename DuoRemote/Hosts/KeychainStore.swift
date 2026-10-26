import Foundation
import Security
import os

extension Logger {
    nonisolated static let keychain = Logger(subsystem: AppInfo.bundleID, category: "keychain")
}

/// Payload-free Keychain failures: only the OSStatus is kept, never the stored value.
nonisolated enum KeychainStoreError: Error, Equatable, Sendable {
    case unhandledError(status: OSStatus)
    case invalidData
}

/// A minimal actor over the generic-password Keychain for small string secrets.
/// Items are `WhenUnlockedThisDeviceOnly`: never synced or backed up.
actor KeychainStore {
    private let service: String

    init(service: String = AppInfo.bundleID) {
        self.service = service
    }

    func get(key: String) throws -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unhandledError(status: status)
        }
    }

    func set(_ value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainStoreError.invalidData }
        let updateStatus = SecItemUpdate(
            baseQuery(account: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(account: key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.unhandledError(status: addStatus) }
        default:
            throw KeychainStoreError.unhandledError(status: updateStatus)
        }
    }

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledError(status: status)
        }
    }

    /// Every account (key) stored under this service.
    func allKeys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            let list = items as? [[String: Any]] ?? []
            return list.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainStoreError.unhandledError(status: status)
        }
    }

    /// Deletes every item under this service.
    func deleteAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension KeychainStore {
    /// Host passwords are filed under the host's UUID.
    func password(forHostID id: UUID) throws -> String? { try get(key: id.uuidString) }
    func setPassword(_ password: String, forHostID id: UUID) throws { try set(password, key: id.uuidString) }
    func deletePassword(forHostID id: UUID) throws { try delete(key: id.uuidString) }
}
