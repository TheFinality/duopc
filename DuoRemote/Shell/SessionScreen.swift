import SwiftUI
import UIKit

/// Full-bleed remote canvas + key bar + status overlay. No navigation bar, no system chrome.
struct SessionScreen: View {
    let session: VNCSession
    let coordinator: SessionCoordinator

    @State private var keyboardShown = false
    @State private var barCollapsed = false
    @State private var barHeight: CGFloat = 0
    @State private var safeInsets = EdgeInsets()
    @State private var composeShown = false
    /// The fold and window size, in window coordinates. The key-bar split comes from these alone,
    /// never from the bar's own size, which the split changes (a feedback loop).
    @State private var fold: CGRect?
    @State private var windowSize: CGSize = .zero
    /// Hinge half-open / fully open (from the Duo's hinge sensor).
    @State private var hingeHalfOpen = false
    @State private var hingeFlat = false
    /// The fold while flat: inactive, zero thickness, but still where the halves meet.
    @State private var flatFold: CGRect?
    /// Full window size from a keyboard-independent view (laptop pose is pinned to this).
    @State private var fullSize: CGSize = .zero
    @AppStorage("deckMode") private var deckMode: DeckMode = .trackpad
    @AppStorage("laptopScreenClicks") private var laptopScreenClicks = false

    #if DEBUG
    private let forceLaptop = ProcessInfo.processInfo.arguments.contains("-laptopDemo")
    #else
    private let forceLaptop = false
    #endif

    /// Laptop pose: the fold running across the window, half-open → screen on top, deck below.
    /// Also when flat, and on any tall window wide enough for the deck (iPad portrait).
    private var laptopFold: CGRect? {
        if forceLaptop, fullSize.height > 0 {
            return CGRect(x: 0, y: fullSize.height * 0.5 - 6, width: fullSize.width, height: 12)
        }
        if hingeHalfOpen, let fold, fold.width > fold.height { return fold }
        if hingeFlat, let flatFold, flatFold.width > flatFold.height { return flatFold }
        // A flat Duo with no fold reported, or any tall window wide enough for a deck (an iPad in
        // portrait): split across the middle.
        if hingeFlat || fullSize.width >= Self.deckMinWidth, fullSize.height > fullSize.width {
            return CGRect(x: 0, y: fullSize.height / 2, width: fullSize.width, height: 0)
        }
        return nil
    }

    private var barSplit: FoldSplit? {
        guard let fold, windowSize.width > 0 else { return nil }
        let minX: CGFloat = 8     // the bar spans the side insets too (see normalLayout)
        let bar = CGRect(x: minX, y: fold.midY, width: windowSize.width - 2 * minX, height: 1)
        return FoldSplit.decide(bar: bar, fold: fold)
    }
    /// Top of the software keyboard (ours or the text box's) in window points; nil when hidden.
    @State private var keyboardTop: CGFloat?

    /// What the key bar's ⌨︎ button shows and does: on if any keyboard is up; turning it off
    /// hides whichever keyboard is open (the text box stays, tap it to type again).
    private var keyboardToggle: Binding<Bool> {
        Binding(
            get: { keyboardShown || keyboardTop != nil },
            set: { show in
                if show {
                    keyboardShown = true
                } else {
                    keyboardShown = false
                    UIApplication.shared.dismissKeyboard()
                }
            })
    }

    /// Safe area (home indicator, keyboard, side bars) plus the key bar standing in it.
    private var obscuredInsets: EdgeInsets {
        var i = safeInsets
        // The side insets are the system's vertical-bar area (e.g. the Duo's outer display).
        // Status and bars are hidden in a session, so the PC's screen may use that space.
        i.leading = 0
        i.trailing = 0
        if !barCollapsed { i.bottom += barHeight }
        return i
    }

    var body: some View {
        base
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeInsets = $0 }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            .background {
                // Measured on a full-window view that ignores the keyboard: when the keyboard rose,
                // the fold briefly fell outside the shrinking view and laptop pose flickered off.
                Color.clear
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { fullSize = $0 }
                    .onGeometryChange(for: CGRect?.self) { DuoFold.division(in: $0) } action: { new in
                        // While half-open, keep the last fold through momentary dropouts.
                        if new != nil || !hingeHalfOpen { fold = new }
                    }
                    .onGeometryChange(for: CGRect?.self) { DuoFold.divisionIncludingInactive(in: $0) } action: { flatFold = $0 }
            }
            .onHingeChange { _, new in
                hingeHalfOpen = new.hinge?.status == .partiallyOpen
                hingeFlat = new.hinge?.status == .fullyOpen
            }
            .onChange(of: laptopFold == nil) { _, notLaptop in
                if notLaptop { keyboardShown = false } else { restoreDeckKeyboard() }
            }
            .onChange(of: keyboardShown) { _, shown in
                // iOS dismisses the keyboard when a fold moves the app between screens; in laptop
                // keyboard mode, bring it back.
                if !shown { restoreDeckKeyboard() }
            }
            .animation(.spring(duration: 0.45, bounce: 0.15), value: laptopFold == nil)
            .modifier(OuterPictureAccessory(unfolded: hingeHalfOpen || hingeFlat))
            .overlay { PasteBeamOverlay() }
            .overlay { FloatingChrome(session: session, coordinator: coordinator, barCollapsed: $barCollapsed) }
            .overlay(alignment: .bottom) {
                // Laptop pose: the text box floats on the keyboard's top edge, or above the key
                // strip in keyboard mode (keyboard avoidance is off in laptop pose, so it's placed
                // by hand).
                if let f = laptopFold, composeShown {
                    let stripTop = deckMode == .keyboard ? f.minY - max((Self.stripHeight - f.height) / 2, 0) : .infinity
                    let top = min(keyboardTop ?? fullSize.height, stripTop)
                    ComposeBox(session: session, isShown: $composeShown)
                        .padding(.bottom, max(fullSize.height - top, 0) + 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background { KeyboardInput(session: session, softwareKeyboardShown: $keyboardShown, isSuspended: composeShown) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                keyboardTop = frame.height > 100 ? frame.minY : nil   // ignore the hardware-keyboard shortcut bar
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardTop = nil
            }
            .onChange(of: composeShown) { was, shown in
                if was, !shown { session.composeDismissed() }
            }
            .onChange(of: session.composeRequests) { _, _ in
                withAnimation(.snappy) { barCollapsed = false; composeShown = true }
            }
            .alert(pasteTitle, isPresented: pasteConfirmShown) {
                Button("Paste") { session.confirmPaste() }
                Button("Cancel", role: .cancel) { session.pendingPaste = nil }
            } message: {
                Text("Line breaks are typed as Shift-Return. Some apps, such as Terminal, treat that as Return and run what's typed.")
            }
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .statusBarHidden()
            // Laptop pose: the keyboard must not push the screen and deck up (SwiftUI's keyboard
            // avoidance did, even with ignoresSafeArea further in). The normal layout keeps it so
            // the key bar rides the keyboard.
            .ignoresSafeArea(.keyboard, edges: laptopFold != nil ? .all : [])
    }

    private var pasteConfirmShown: Binding<Bool> {
        Binding(get: { session.pendingPaste != nil }, set: { if !$0 { session.pendingPaste = nil } })
    }

    private var pasteTitle: String {
        let lines = KeyMapping.pasteLines(session.pendingPaste ?? "")
        let chars = lines.reduce(0) { $0 + $1.count }
        return "Paste \(chars.formatted()) characters on \(lines.count.formatted()) \(lines.count == 1 ? "line" : "lines")?"
    }

    private func restoreDeckKeyboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard laptopFold != nil, deckMode == .keyboard, !composeShown, !keyboardShown else { return }
            keyboardShown = true
        }
    }

    @ViewBuilder private var base: some View {
        if let f = laptopFold {
            laptopLayout(fold: f)
        } else {
            normalLayout
        }
    }

    /// Screen on the top half, deck on the bottom half. The screen is look-only unless Settings
    /// allows clicks there (then it uses the session's input mode): resting a hand on it while
    /// typing shouldn't click.
    private func laptopLayout(fold f: CGRect) -> some View {
        // Pinned to the full window: a GeometryReader places its child at the window's origin,
        // and the explicit size never changes with the keyboard, so nothing can push it up.
        GeometryReader { _ in
            laptopStack(fold: f)
                .frame(width: fullSize.width, height: fullSize.height, alignment: .top)
        }
        .ignoresSafeArea()
    }

    private static let stripHeight: CGFloat = 54
    /// Narrower tall windows (phones, iPad split view) keep the key bar.
    private static let deckMinWidth: CGFloat = 700

    private func laptopStack(fold f: CGRect) -> some View {
        // Keyboard mode: the key strip sits centred on the fold (the gutter between the PC's
        // screen and the keyboard) instead of taking height from the screen.
        let overhang = deckMode == .keyboard ? max((Self.stripHeight - f.height) / 2, 0) : 0
        return VStack(spacing: 0) {
            RemoteCanvas(session: session, inputModeOverride: laptopScreenClicks ? nil : .view)
                .frame(height: max(f.minY - overhang, 0))
            if deckMode == .keyboard {
                LaptopKeyStrip(session: session)
                    .frame(height: f.height + 2 * overhang)
                    .transition(.opacity)
            } else {
                Color.black.frame(height: f.height)
            }
            LaptopDeck(session: session, coordinator: coordinator, mode: $deckMode,
                       keyboardShown: $keyboardShown, composeShown: $composeShown,
                       bottomInset: safeInsets.bottom)
                .transition(.move(edge: .bottom))
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: deckMode)
        .ignoresSafeArea()
    }

    private var normalLayout: some View {
        RemoteCanvas(session: session, obscuredInsets: obscuredInsets)
            .ignoresSafeArea()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !barCollapsed {
                    VStack(spacing: 6) {
                        if composeShown {
                            ComposeBox(session: session, isShown: $composeShown)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        SessionBar(session: session, coordinator: coordinator, split: barSplit,
                                   keyboardShown: keyboardToggle, composeShown: $composeShown) {
                            withAnimation(.snappy) { barCollapsed = true }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .ignoresSafeArea(.container, edges: .horizontal)   // use the side-bar area too
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }
}

/// The key bar, split either side of a vertical fold when one crosses it.
private struct SessionBar: View {
    let session: VNCSession
    let coordinator: SessionCoordinator
    let split: FoldSplit?
    @Binding var keyboardShown: Bool
    @Binding var composeShown: Bool
    let collapse: () -> Void

    var body: some View {
        content
            .padding(.horizontal, 8)
            // The whole bar catches touches, so a tap between buttons never falls through to
            // the canvas behind it (which would click the PC).
            .background { Color.black.opacity(0.001).padding(.vertical, -4) }
    }

    @ViewBuilder private var content: some View {
        if let split {
            // Fold crosses the bar: modifiers + keyboard on the leading page, navigation keys +
            // session controls on the trailing one, so no key sits on the fold.
            // Each half scrolls, so its content can never push the bar wider than the split allows.
            FoldSplitRow(split: split) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        KeyBarModifierKeys(session: session)
                        KeyBarKeyboardToggle(shown: $keyboardShown)
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            } right: {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        KeyBarMouseKeys(session: session)
                        KeyBarNavigationKeys(session: session)
                        controls
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
        } else {
            KeyBar(session: session, keyboardShown: $keyboardShown) { controls }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .clipShape(.rect(cornerRadius: 22))   // keep the scrolling key row inside the bar
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button("Text box", systemImage: composeShown ? "text.bubble.fill" : "text.bubble") {
                withAnimation(.snappy) { composeShown.toggle() }
            }
            .barButton()
            // Blue (filled) while the text box is open, plain while it's closed.
            .foregroundStyle(composeShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .accessibilityValue(composeShown ? "On" : "Off")
            Button("Paste to PC", systemImage: "doc.on.clipboard", action: session.pasteClipboard)
                .barButton()
                .pasteBeamSource()
            Button("Hide keys", systemImage: "chevron.down", action: collapse)
                .labelStyle(.iconOnly)
                .frame(minWidth: 36, minHeight: 36)
            SessionMenu(session: session, coordinator: coordinator)
            Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right") {
                coordinator.disconnect()     // → back to the hosts list
            }
            .barButton()
            .tint(.red)
        }
        .padding(.horizontal, 8)
    }
}

private extension View {
    func barButton() -> some View {
        labelStyle(.iconOnly)
            .font(.title3)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}

/// Round trip, frame rate and bitrate in a corner (••• → Connection info). Amber while the network
/// is backing up; "cap" shows automatic quality has lowered the bitrate.
private struct ConnectionBadge: View {
    let stats: VideoStats

    var body: some View {
        let mbps = Double(stats.kbps) / 1000
        let lowered = stats.capKbps.flatMap { $0 < PictureQuality.current.videoBitrateKbps ? $0 / 1000 : nil }
        HStack(spacing: 6) {
            Circle()
                .fill(stats.isStrained ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text("\(stats.roundTripMs) ms · \(stats.fps) fps · \(mbps, format: .number.precision(.fractionLength(1))) Mbps")
            if let lowered { Text("· cap \(lowered)").foregroundStyle(.orange) }
        }
        .font(.caption2.monospacedDigit().weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Status overlay, the collapsed-bar button and the connection badge. All stay on the larger side of any fold.
private struct FloatingChrome: View {
    let session: VNCSession
    let coordinator: SessionCoordinator
    @Binding var barCollapsed: Bool
    @State private var clear: CGRect?
    @AppStorage("showConnectionInfo") private var showConnectionInfo = false

    var body: some View {
        GeometryReader { proxy in
            let full = CGRect(origin: .zero, size: proxy.size)
            let region = clear ?? full
            ZStack(alignment: .topLeading) {
                status
                    .position(x: region.midX, y: region.midY)
                if showConnectionInfo, session.isVideo, let stats = session.videoStats {
                    ConnectionBadge(stats: stats)
                        .padding(12)
                        .frame(width: region.width, height: region.height, alignment: .topTrailing)
                        .position(x: region.midX, y: region.midY)
                        .transition(.opacity)
                }
                if barCollapsed {
                    Button("Show keys", systemImage: "keyboard.chevron.compact.up") {
                        withAnimation(.snappy) { barCollapsed = false }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .position(x: region.minX + 16 + 22, y: region.maxY - 16 - 22)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onGeometryChange(for: CGRect.self) { p in
                foldClearRegion(container: CGRect(origin: .zero, size: p.size), fold: DuoFold.division(in: p))
            } action: { clear = $0 }
        }
    }

    @ViewBuilder private var status: some View {
        // A retry first looks the PC up again (the Tailscale check); show that as connecting too.
        let lookingUp = coordinator.activeHost.map { $0.id == coordinator.lookingUpHostID } ?? false
        switch session.status {
        case .connecting:
            connecting
        case _ where lookingUp:
            connecting
        case .connected where session.isVideo && session.videoNotice != nil:
            // The PC can't capture its screen right now (lock screen, admin prompt): VNC can.
            VStack(spacing: 12) {
                Text(session.videoNotice ?? "").multilineTextAlignment(.center)
                Button("Use VNC for now") { coordinator.setVideoStreaming(false) }
                    .buttonStyle(.glassProminent)
            }
            .padding(18)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        case .disconnected(let failure?):
            VStack(spacing: 12) {
                Text("Disconnected: \(Self.reason(failure))").multilineTextAlignment(.center)
                HStack {
                    Button("Retry") {
                        if let host = coordinator.activeHost { coordinator.connect(host) }
                    }
                    .buttonStyle(.glassProminent)
                    Button("Close") { coordinator.disconnect() }
                        .buttonStyle(.glass)
                }
            }
            .padding(18)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        default:
            EmptyView()
        }
    }

    private var connecting: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Connecting to \(coordinator.activeHost?.name ?? session.hostname)…")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }

    private static func reason(_ f: VNCSession.Failure) -> String {
        switch f {
        case .authenticationFailed: "authentication failed"
        case .network(let m): m
        case .closedByServer: "closed by the PC"
        case .outsideTailscale: "this PC isn't reached through Tailscale, so your saved password wasn't sent"
        case .gatewayCertificateMismatch: "the PC's certificate isn't the one you paired with. If you set the gateway up again, pair again; otherwise something else is answering at this address, so nothing was sent"
        case .gatewayRejected: "the gateway doesn't recognise this \(AppInfo.device). Pair again: on the PC run DuoPCGateway pair, then in Edit PC tap Scan pairing code"
        case .insecureAuthentication: "this PC didn't ask for a password (or asked for a kind of sign-in Windows VNC servers don't use), so the app didn't continue. Set a password in your VNC server, or to allow it anyway, turn on Allow outside Tailscale in Edit PC."
        }
    }
}
