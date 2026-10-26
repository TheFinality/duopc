import Foundation
import Observation
import os

/// Saved hosts, persisted as JSON in Application Support. Passwords are not here (see `keychain`).
@Observable
final class HostStore {
    private(set) var hosts: [Host]
    @ObservationIgnored let keychain: KeychainStore
    @ObservationIgnored private let fileURL: URL

    private struct Payload: Codable {
        var hosts: [Host]
    }

    /// - Parameter fileURL: where to persist; defaults to Application Support/hosts.json.
    init(fileURL: URL? = nil, keychain: KeychainStore = KeychainStore()) {
        let url = fileURL ?? Self.defaultFileURL()
        self.fileURL = url
        self.keychain = keychain

        let data = try? Data(contentsOf: url)
        hosts = data.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }?.hosts ?? []
    }

    func add(_ host: Host) {
        hosts.append(host)
        save()
    }

    func update(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    /// Removes the host and its Keychain password. (A password left behind by a failed delete is
    /// removed by `tidyKeychain` on the next launch.)
    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        save()
        let keychain = keychain
        let id = host.id
        Task {
            do { try await keychain.deletePassword(forHostID: id) } catch {
                Logger.keychain.error("Couldn't delete a removed Mac's password: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// At launch: the Keychain outlives the app, so after a fresh install (no saved hosts, no flag)
    /// wipe what an earlier install left; otherwise drop passwords whose Mac is gone.
    func tidyKeychain(defaults: UserDefaults = .standard) async {
        let flag = "keychainInitialised"
        let freshInstall = !defaults.bool(forKey: flag) && !FileManager.default.fileExists(atPath: fileURL.path)
        let known = Set(hosts.map(\.id.uuidString))
        do {
            if freshInstall {
                try await keychain.deleteAll()
            } else {
                for key in try await keychain.allKeys() where !known.contains(key) {
                    try await keychain.delete(key: key)
                }
            }
            defaults.set(true, forKey: flag)
        } catch {
            Logger.keychain.error("Keychain tidy-up failed: \(String(describing: error), privacy: .public)")
        }
    }

    func host(withID id: UUID) -> Host? { hosts.first { $0.id == id } }

    private func save() {
        let payload = Payload(hosts: hosts)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "hosts.json")
    }
}
