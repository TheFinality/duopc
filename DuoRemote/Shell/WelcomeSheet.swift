import SwiftUI

/// First-launch welcome and help: what the app is, setup, gestures and the plain-words disclaimers.
/// Shown once automatically (`hasSeenWelcome`), and re-openable from the hosts screen.
struct WelcomeSheet: View {
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                setupCard
                gesturesCard
                securityCard
                Text("Independent project, not affiliated with, sponsored or endorsed by Apple Inc. or Tailscale Inc. Apple and iPhone are trademarks of Apple Inc. Windows is a trademark of Microsoft Corporation. Tailscale is a trademark of Tailscale Inc. TightVNC is a trademark of GlavSoft LLC. Provided as-is, with no warranty. Use at your own risk, and only with computers you own or are authorised to access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background { WelcomeBackground() }
        .safeAreaBar(edge: .bottom) {
            Button(action: onDone) {
                Text("Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.indigo)
            .frame(maxWidth: 600)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "pc")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            Text("Welcome to \(AppInfo.name)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("See and control your Windows PC from your \(AppInfo.device), at home or away, over an encrypted connection straight to your PC.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var setupCard: some View {
        WelcomeCard(title: "Set up in 3 steps", symbol: "list.number") {
            VStack(alignment: .leading, spacing: 16) {
                step(1, "Set up your PC",
                     "On your PC, run Setup-DuoPC.ps1 as administrator. It installs the free TightVNC server and DuoPC Gateway, an encrypted way in, and shows a QR code.")
                step(2, "Open a port",
                     "To connect away from home, forward the gateway's port (5960) on your router to your PC. The script tells you what to enter.")
                step(3, "Scan the code",
                     "Tap + on the home screen, then Scan pairing code.")
            }
        }
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [.indigo, .blue], startPoint: .top, endPoint: .bottom), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var gesturesCard: some View {
        WelcomeCard(title: "Gestures", symbol: "hand.tap") {
            VStack(alignment: .leading, spacing: 12) {
                gesture("hand.point.up.left", "Drag", "moves the pointer")
                gesture("hand.tap", "Tap", "clicks")
                gesture("hand.tap.fill", "Two-finger tap", "right-clicks")
                gesture("arrow.up.and.down.and.arrow.left.and.right", "Two-finger drag", "scrolls")
                gesture("hand.draw", "Hold, then drag", "drags")
                gesture("arrow.up.left.and.arrow.down.right", "Pinch", "zooms")
                gesture("hand.raised.fingers.spread", "Three-finger drag", "pans when zoomed in")
                Divider()
                Label {
                    Text("**Laptop pose on iPhone Duo.** Fold it halfway: the PC's screen is on top, and a trackpad and keys are below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "laptopcomputer").foregroundStyle(.indigo)
                }
            }
        }
    }

    private func gesture(_ symbol: String, _ name: LocalizedStringKey, _ effect: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.indigo)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(name).font(.subheadline.weight(.semibold))
            Text(effect).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var securityCard: some View {
        WelcomeCard(title: "Good to know", symbol: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                point("Paired PCs: everything is encrypted with TLS 1.3, and the app talks only to the PC whose certificate it paired with, so a fake server gets nothing.")
                point("The gateway lets in only paired phones, and blocks an address for an hour after repeated wrong tries. TightVNC itself can't be reached from the network at all.")
                point("PCs added by hand, without pairing, use plain VNC, which isn't encrypted. For those, a saved password is sent only over Tailscale; anywhere else the app asks first.")
                point("Passwords stay in this \(AppInfo.device)'s Keychain.")
                point("No accounts, no analytics, no servers.")
            }
        }
    }

    private func point(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(.indigo).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct WelcomeCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28, style: .continuous))
    }
}

private struct WelcomeBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            RadialGradient(colors: [.indigo.opacity(0.30), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [.cyan.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}
