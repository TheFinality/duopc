@preconcurrency import RoyalVNCKit
import SwiftUI
import os

/// Asks for a host's username + password, then connects. When the Mac isn't reached through
/// Tailscale, it says so first and the password is sent only if the user goes ahead.
struct CredentialSheet: View {
    let host: Host
    let coordinator: SessionCoordinator

    @State private var username: String
    @State private var password = ""
    @State private var saveInKeychain = true
    @State private var allowOutside: Bool
    private let outsideAddress: String?

    init(host: Host, coordinator: SessionCoordinator) {
        self.host = host
        self.coordinator = coordinator
        outsideAddress = coordinator.outsideTailscaleAddress
        _username = State(initialValue: host.username)
        _allowOutside = State(initialValue: host.allowOutsideTailscale)
    }

    private var canConnect: Bool {
        !username.isEmpty && !password.isEmpty && VNCCredentialLimit.fits(username) && VNCCredentialLimit.fits(password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(nil)   // not a website login: keep iOS Passwords from offering to save/update it
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(nil)
                } header: {
                    Text("\(host.name) (\(host.hostname))")
                } footer: {
                    if !VNCCredentialLimit.fits(username) || !VNCCredentialLimit.fits(password) {
                        ErrorText(CredentialText.tooLong)
                    }
                }
                if let outsideAddress {
                    Section {
                        Label {
                            Text("\(host.hostname) isn't reached through Tailscale (it's at \(outsideAddress)). Anyone on this network could pretend to be your Mac and capture the password you send. Connect only if you trust this network.")
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                        }
                        Toggle("Always allow for this Mac", isOn: $allowOutside)
                    } header: {
                        Text("Not on Tailscale")
                    } footer: {
                        Text("Your saved password isn't sent outside Tailscale unless you allow it. You can change this in Edit Mac.")
                    }
                }
                Section {
                    Toggle("Save in Keychain", isOn: $saveInKeychain)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.credentialPrompt = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(outsideAddress == nil ? "Connect" : "Connect Anyway", action: connect)
                        .disabled(!canConnect)
                }
            }
        }
    }

    private func connect() {
        var target = coordinator.store.host(withID: host.id) ?? host
        if saveInKeychain { target.username = username }
        if outsideAddress != nil { target.allowOutsideTailscale = allowOutside }
        coordinator.store.update(target)
        let keychain = coordinator.store.keychain
        let id = target.id
        let secret = saveInKeychain ? password : nil
        Task {
            do {
                if let secret {
                    try await keychain.setPassword(secret, forHostID: id)
                } else {
                    try await keychain.deletePassword(forHostID: id)
                }
            } catch {
                Logger.keychain.error("Couldn't update the saved password: \(String(describing: error), privacy: .public)")
            }
        }
        target.username = username
        coordinator.credentialPrompt = nil
        coordinator.connect(target, username: username, password: password, approvedAddress: outsideAddress)
    }
}

enum CredentialText {
    static let tooLong = "Screen Sharing accepts usernames and passwords up to 63 bytes: about 63 letters, fewer with accents or emoji."
}
