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
                Text("Independent project, not affiliated with, sponsored or endorsed by Apple Inc. or Tailscale Inc. Apple, iPhone, Mac and macOS are trademarks of Apple Inc. Tailscale is a trademark of Tailscale Inc. Provided as-is, with no warranty. Use at your own risk, and only with computers you own or are authorised to access.")
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
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            Text("Welcome to \(AppInfo.name)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("See and control your Mac from your \(AppInfo.device), using the Screen Sharing built into macOS. There is nothing to install on the Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var setupCard: some View {
        WelcomeCard(title: "Set up in 3 steps", symbol: "list.number") {
            VStack(alignment: .leading, spacing: 16) {
                step(1, "Turn on Screen Sharing",
                     "On your Mac, open System Settings → General → Sharing and switch on Screen Sharing.")
                step(2, "Connect the two",
                     "Install [Tailscale](https://tailscale.com) on your Mac and \(AppInfo.device) to connect from anywhere, or put both on the same network. With Tailscale, turn on MagicDNS so you can use your Mac's name instead of its IP address.")
                step(3, "Add your Mac",
                     "Tap + on the home screen, then sign in with your Mac's username and password.")
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
                    Text("**Laptop pose on iPhone Duo.** Fold it halfway: the Mac's screen is on top, and a trackpad and keys are below.")
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
                point("macOS Screen Sharing doesn't encrypt what's on your screen or what you type, beyond the sign-in. Use Tailscale or a network you trust.")
                point("The app can't verify the identity of the Mac it connects to. If you connect outside Tailscale, a fake server on that network could capture your Mac's password.")
                point("So a saved password is sent only when your Mac is reached through Tailscale. Anywhere else, the app asks first.")
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
