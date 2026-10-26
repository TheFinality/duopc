@preconcurrency import RoyalVNCKit
import SwiftUI
import os

/// The home screen: a hero header, one card per saved Mac, and a Help row.
/// Tap a card to connect; the ••• menu (or a long-press) edits or deletes.
struct HostsListView: View {
    let coordinator: SessionCoordinator

    private enum EditorTarget: Identifiable {
        case new
        case edit(Host)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let host): host.id.uuidString
            }
        }
    }

    @State private var editor: EditorTarget?
    @State private var showSettings = false
    @State private var pendingDelete: Host?
    @State private var reachability = ReachabilityModel()
    @State private var showWelcome = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    private var store: HostStore { coordinator.store }

    /// Changes only when a host is added/removed or its address changes (not when `lastConnected` does).
    private var probeKey: [String] { store.hosts.map { "\($0.id)\($0.hostname):\($0.port)" } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HeroHeader(
                        reports: Diagnostics.reports(),
                        onSettings: { showSettings = true },
                        onHelp: { showWelcome = true },
                        onAdd: { editor = .new }
                    )

                    if store.hosts.isEmpty {
                        OnboardingCard(onAdd: { editor = .new }, onDemo: coordinator.openDemo, onHelp: { showWelcome = true })
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                            ForEach(store.hosts) { host in
                                HostCard(
                                    host: host,
                                    state: reachability.state(for: host),
                                    connecting: coordinator.lookingUpHostID == host.id,
                                    onConnect: { coordinator.connect(host) },
                                    onEdit: { editor = .edit(host) },
                                    onDelete: { pendingDelete = host }
                                )
                            }
                            AddMacCard { editor = .new }
                        }

                        ListRowButton(title: "Try the demo", systemImage: "play.rectangle", action: coordinator.openDemo)
                        ListRowButton(title: "Help", systemImage: "questionmark.circle") { showWelcome = true }
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .background { HomeBackground() }
            .refreshable { await runProbe() }
            .task(id: probeKey) { await runProbe() }
            .onDisappear { reachability.cancel() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(item: $editor) { target in
                switch target {
                case .new: HostEditor(host: nil, store: store)
                case .edit(let host): HostEditor(host: host, store: store)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
                WelcomeSheet { showWelcome = false }
            }
            .onAppear { if !hasSeenWelcome { showWelcome = true } }
            .confirmationDialog(
                "Delete this Mac?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { host in
                Button("Delete \(host.name)", role: .destructive) { store.delete(host) }
            } message: { host in
                Text("\(host.name) and its saved password will be removed from this \(AppInfo.device).")
            }
        }
    }

    private func runProbe() async {
        let run = reachability.refresh(store.hosts)
        await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
    }
}

// MARK: - Background and header

/// The hero glow: a mesh gradient in the current sky colours that drifts slowly (still when
/// effects are off, Reduce Motion is on or Low Power Mode is on).
private struct HomeBackground: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let theme = SkyTheme.shared
        let rim = theme.rim
        let motion = theme.motion
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            TimelineView(.animation(minimumInterval: 1.0 / 8, paused: !motion || scenePhase != .active)) { ctx in
                let t = motion ? ctx.date.timeIntervalSinceReferenceDate : 0
                MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colors(rim))
                    .frame(height: 520)
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
            }
        }
        .ignoresSafeArea()
    }

    private static func colors(_ rim: [Color]) -> [Color] {
        let a = 0.5, b = 0.25
        return [rim[0].opacity(a), rim[1].opacity(a), rim[2].opacity(a),
                rim[1].opacity(b), rim[2].opacity(b), rim[0].opacity(b),
                rim[2].opacity(0), rim[0].opacity(0), rim[1].opacity(0)]
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func d(_ i: Double, _ amp: Double = 0.07) -> Float { Float(amp * sin(t * 0.18 + i * 1.7)) }
        return [
            [0, 0], [0.5 + d(1), 0], [1, 0],
            [0, 0.5 + d(2)], [0.5 + d(3), 0.5 + d(4)], [1, 0.5 + d(5)],
            [0, 1], [0.5 + d(6), 1], [1, 1]
        ]
    }
}

private struct HeroHeader: View {
    let reports: [URL]
    let onSettings: () -> Void
    let onHelp: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppInfo.name)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.primary, .primary.opacity(0.65)],
                                                    startPoint: .leading, endPoint: .trailing))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("Your Macs, always within reach.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if !reports.isEmpty {
                    // MetricKit crash/hang reports saved by the app (see Diagnostics).
                    ShareLink(items: reports) {
                        Label("Crash reports (\(reports.count))", systemImage: "ladybug")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                }
                Button("Welcome and help", systemImage: "questionmark.circle", action: onHelp)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                Button("Settings", systemImage: "gearshape", action: onSettings)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                Button("Add Mac", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
            }
            .font(.body.weight(.semibold))
        }
        .padding(.top, 12)
    }
}

// MARK: - Cards

extension Host {
    /// Accent gradient for the host's icon tile.
    var tintColors: [Color] {
        switch symbolName {
        case "macmini": [.indigo, .purple]
        case "laptopcomputer": [.teal, .blue]
        case "macstudio": [.pink, .indigo]
        case "display": [.green, .teal]
        default: [.orange, .pink]
        }
    }
}

private struct SymbolTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 60

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: size * 0.3, style: .continuous)
            )
            .shadow(color: colors[0].opacity(0.35), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// The status dot; when online it gives a calm heartbeat pulse with an expanding ring.
private struct HeartbeatDot: View {
    let color: Color
    let beating: Bool

    var body: some View {
        let dot = Circle().fill(color).frame(width: 8, height: 8)
        if beating && SkyTheme.shared.motion {
            dot.keyframeAnimator(initialValue: 0.0, repeating: true) { view, p in
                view
                    .scaleEffect(1 + 0.25 * sin(.pi * min(p * 2, 1)))
                    .background {
                        Circle().stroke(color, lineWidth: 1.5)
                            .scaleEffect(1 + 1.6 * p)
                            .opacity(0.6 * (1 - p))
                    }
            } keyframes: { _ in
                LinearKeyframe(1.0, duration: 0.9)
                LinearKeyframe(1.0, duration: 1.1)
            }
        } else {
            dot
        }
    }
}

private struct StatusPill: View {
    let state: ReachabilityState
    var connecting = false

    private var title: LocalizedStringKey {
        if connecting { return "Connecting…" }
        return switch state {
        case .online: "Online"
        case .offline: "Offline"
        case .checking: "Checking…"
        }
    }

    private var color: Color {
        switch state {
        case .online: .green
        case .offline: .gray
        case .checking: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if connecting || state == .checking {
                ProgressView().controlSize(.mini)
            } else {
                HeartbeatDot(color: color, beating: state == .online)
            }
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(state == .online ? Color.green : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: .capsule)
        .animation(.easeInOut(duration: 0.2), value: state)
        .animation(.easeInOut(duration: 0.2), value: connecting)
        .accessibilityElement(children: .combine)
    }
}

private struct HostCard: View {
    let host: Host
    let state: ReachabilityState
    let connecting: Bool
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var taps = 0

    private var subtitle: String {
        host.username.isEmpty ? host.hostname : "\(host.hostname) · \(host.username)"
    }

    private var lastConnectedText: String {
        guard let date = host.lastConnected else { return "Not connected yet" }
        return "Last connected " + date.formatted(.relative(presentation: .named))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                taps += 1
                onConnect()
            } label: {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 14) {
                        SymbolTile(symbol: host.symbolName, colors: host.tintColors)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name).font(.headline).lineLimit(1)
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 44)   // room for the ••• menu
                    }
                    HStack(spacing: 10) {
                        StatusPill(state: state, connecting: connecting)
                        Text(lastConnectedText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        Color(.secondarySystemGroupedBackground)
                        LinearGradient(colors: host.tintColors.map { $0.opacity(0.16) },
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .clipShape(.rect(cornerRadius: 28, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(host.tintColors[0].opacity(0.25), lineWidth: 1)
                }
                .contentShape(.rect(cornerRadius: 28, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .accessibilityLabel("\(host.name), \(subtitle)")
            .accessibilityHint("Connects to this Mac")

            Menu {
                Button("Connect", systemImage: "play.fill", action: onConnect)
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Actions for \(host.name)")
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .contextMenu {
            Button("Connect", systemImage: "play.fill", action: onConnect)
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

private struct AddMacCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                Text("Add a Mac").font(.headline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 88)
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            }
            .contentShape(.rect(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Getting started

private struct GettingStartedSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(1, "Turn on Screen Sharing",
                 "On your Mac, open System Settings → General → Sharing and switch on Screen Sharing.")
            step(2, "Connect the two",
                 "Put your \(AppInfo.device) and Mac on the same network, or install [Tailscale](https://tailscale.com) on both to connect from anywhere. With Tailscale, turn on MagicDNS and use your Mac's name.")
            step(3, "Add your Mac",
                 "Add your Mac here and sign in with your Mac's username and password.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
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
}

private struct ListRowButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingCard: View {
    let onAdd: () -> Void
    let onDemo: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SymbolTile(symbol: "macbook.and.iphone", colors: [.indigo, .cyan], size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Get started").font(.title2.bold())
                Text("Three steps and your Mac is on your \(AppInfo.device).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            GettingStartedSteps()
            Button(action: onAdd) {
                Text("Add your first Mac")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.indigo)
            Button(action: onDemo) {
                Label("Try the demo first", systemImage: "play.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            Button("Gestures, security and more", systemImage: "questionmark.circle", action: onHelp)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(.secondarySystemGroupedBackground)
                LinearGradient(colors: [.indigo.opacity(0.14), .cyan.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(.rect(cornerRadius: 32, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.indigo.opacity(0.25), lineWidth: 1)
        }
    }
}

// MARK: - Editor

/// Add/edit sheet. The password goes to the Keychain, never to the host file.
struct HostEditor: View {
    let host: Host?
    let store: HostStore

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hostname: String
    @State private var portText: String
    @State private var username: String
    @State private var symbol: String
    @State private var password = ""
    @State private var passwordLoaded: Bool
    @State private var allowOutside: Bool
    @State private var showErrors = false

    init(host: Host?, store: HostStore) {
        self.host = host
        self.store = store
        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _portText = State(initialValue: String(host?.port ?? 5900))
        // A new Mac usually shares your username; the password is always per Mac.
        let lastUsername = store.hosts.max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }?.username ?? ""
        _username = State(initialValue: host?.username ?? lastUsername)
        _symbol = State(initialValue: host?.symbolName ?? HostSymbol.defaultName)
        _passwordLoaded = State(initialValue: host == nil)
        _allowOutside = State(initialValue: host?.allowOutsideTailscale ?? false)
    }

    private var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    private var nameError: String? {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give this Mac a name." : nil
    }

    private var hostnameError: String? {
        hostname.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the Mac's name or IP address." : nil
    }

    private var credentialError: String? {
        VNCCredentialLimit.fits(username) && VNCCredentialLimit.fits(password) ? nil : CredentialText.tooLong
    }

    private var portError: String? {
        port == nil ? "Port must be between 1 and 65535." : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("Name", text: $name)
                    if showErrors, let nameError { ErrorText(nameError) }
                    SymbolPicker(selection: $symbol)
                }
                Section("Connection") {
                    TextField("Hostname", text: $hostname, prompt: Text("my-mac or 100.x.x.x"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if showErrors, let hostnameError { ErrorText(hostnameError) }
                    LabeledContent("Port") {
                        TextField("5900", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if showErrors, let portError { ErrorText(portError) }
                }
                Section {
                    TextField("Username", text: $username)
                        .textContentType(nil)   // not a website login: keep iOS Passwords from offering to save/update it
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(nil)
                    if let credentialError { ErrorText(credentialError) }
                } header: {
                    Text("Sign-in")
                } footer: {
                    Text("With Tailscale, use the Mac's MagicDNS name (for example my-mac). Turn on MagicDNS in the Tailscale admin console under DNS. An IP address works too. Your password is stored in this \(AppInfo.device)'s Keychain.")
                }
                Section {
                    Toggle("Allow outside Tailscale", isOn: $allowOutside)
                } footer: {
                    Text("Normally your saved password is sent only when this Mac is reached through Tailscale, and only to a macOS sign-in. Turn this on to also send it over other networks, or to a Mac that asks for a plain VNC password. On a network you don't trust, a fake server could capture your Mac's password.")
                }
            }
            .navigationTitle(host == nil ? "New Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                }
            }
            .task { await loadPassword() }
        }
    }

    private func loadPassword() async {
        guard let host, !passwordLoaded else { return }
        let saved = try? await store.keychain.password(forHostID: host.id)
        password = (saved ?? nil) ?? ""
        passwordLoaded = true
    }

    private func save() {
        guard nameError == nil, hostnameError == nil, credentialError == nil, let port else {
            showErrors = true
            return
        }
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        var result = host ?? Host(name: "", hostname: "", username: "")
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.hostname = trimmedHost
        result.port = port
        result.username = username.trimmingCharacters(in: .whitespaces)
        result.symbol = symbol
        result.allowOutsideTailscale = allowOutside

        if host == nil { store.add(result) } else { store.update(result) }

        if passwordLoaded {
            let keychain = store.keychain
            let id = result.id
            let secret = password
            Task {
                do {
                    if secret.isEmpty {
                        try await keychain.deletePassword(forHostID: id)
                    } else {
                        try await keychain.setPassword(secret, forHostID: id)
                    }
                } catch {
                    Logger.keychain.error("Couldn't update the saved password: \(String(describing: error), privacy: .public)")
                }
            }
        }
        dismiss()
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

private struct SymbolPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
            ForEach(HostSymbol.all, id: \.self) { name in
                let selected = name == selection
                Button {
                    selection = name
                } label: {
                    Image(systemName: name)
                        .font(.title3)
                        .foregroundStyle(selected ? .white : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            selected
                                ? AnyShapeStyle(LinearGradient(colors: Host(name: "", hostname: "", username: "", symbol: name).tintColors,
                                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color(.tertiarySystemFill)),
                            in: .rect(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(HostSymbol.label(name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
