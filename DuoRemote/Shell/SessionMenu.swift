import SwiftUI

/// The key bar's trailing accessory: input mode, zoom commands, disconnect.
struct SessionMenu: View {
    @Bindable var session: VNCSession
    let coordinator: SessionCoordinator
    @State private var showLog = false
    @State private var showScrollSpeed = false
    @State private var liveText: LiveTextImage?
    @State private var showCopyIntro = false
    @State private var continueToCopy = false
    @AppStorage("hasSeenCopyTextIntro") private var hasSeenCopyIntro = false
    @AppStorage("autoCompose") private var autoCompose = true

    private func openCopyText() {
        if let img = session.visibleSnapshot() { liveText = LiveTextImage(image: img) }
    }

    var body: some View {
        Menu {
            Picker("Input mode", selection: $session.inputMode) {
                Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag(InputMode.trackpad)
                Label("Direct touch", systemImage: "hand.tap").tag(InputMode.direct)
            }
            Toggle(isOn: $autoCompose) {
                Label("Text box on click into text", systemImage: "character.cursor.ibeam")
            }
            Section {
                Button("Zoom to fit", systemImage: "arrow.down.right.and.arrow.up.left") { session.zoomToFit() }
                Button("Actual pixels", systemImage: "1.magnifyingglass") { session.zoomToActualPixels() }
            }
            Section {
                Button("Copy text from screen", systemImage: "text.viewfinder") {
                    if hasSeenCopyIntro { openCopyText() } else { showCopyIntro = true }
                }
            }
            Section {
                Button("Scroll speed…", systemImage: "arrow.up.and.down.text.horizontal") { showScrollSpeed = true }
                Button("Connection log", systemImage: "list.bullet.rectangle") { showLog = true }
            }
            Section {
                Button("Disconnect", systemImage: "xmark", role: .destructive) { coordinator.disconnect() }
            }
        } label: {
            Label("Session", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(minWidth: 36, minHeight: 36)
        }
        .sheet(isPresented: $showLog) { ConnectionLogView(session: session) }
        .sheet(isPresented: $showScrollSpeed) { ScrollSpeedSheet(session: session, coordinator: coordinator) }
        .fullScreenCover(item: $liveText) { LiveTextSheet(image: $0.image) }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-copyTextIntro") { showCopyIntro = true }
            if args.contains("-copyTextScreen") { openCopyText() }
        }
        #endif
        .sheet(isPresented: $showCopyIntro, onDismiss: {
            // Present the copy view only once the intro sheet has fully closed.
            if continueToCopy { continueToCopy = false; openCopyText() }
        }) {
            CopyTextIntro(onContinue: {
                hasSeenCopyIntro = true
                continueToCopy = true
                showCopyIntro = false
            }, onCancel: { showCopyIntro = false })
        }
    }
}

/// Recent connection events — e.g. to see whether the Mac sends clipboard messages at all.
struct ConnectionLogView: View {
    let session: VNCSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(session.eventLog.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                .overlay { if session.eventLog.isEmpty { ContentUnavailableView("No events yet", systemImage: "list.bullet") } }
                .navigationTitle("Connection log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: session.eventLog.joined(separator: "\n"))
                    }
                    ToolbarItem(placement: .bottomBar) {
                        let reports = Diagnostics.reports()
                        if reports.isEmpty {
                            Text("No crash reports").foregroundStyle(.secondary)
                        } else {
                            ShareLink(items: reports) {
                                Label("Crash reports (\(reports.count))", systemImage: "ladybug")
                            }
                        }
                    }
                }
        }
    }
}

/// Identifiable wrapper so a snapshot can drive `fullScreenCover(item:)`.
struct LiveTextImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// This Mac's scroll speed: follow the global default, or set its own. Applies immediately.
struct ScrollSpeedSheet: View {
    let session: VNCSession
    let coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var speed = VNCSession.defaultScrollSpeed

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use the default (\(VNCSession.globalScrollSpeed, format: .number.precision(.fractionLength(1)))×)", isOn: Binding(
                        get: { !custom },
                        set: { custom = !$0; apply() }))
                    if custom {
                        VStack(alignment: .leading) {
                            Text("\(speed, format: .number.precision(.fractionLength(2)))×").font(.title3.monospacedDigit())
                            Slider(value: $speed, in: 1...5, step: 0.25) { _ in apply() }
                        }
                    }
                } footer: {
                    Text("Applies straight away and is remembered for \(coordinator.activeHost?.name ?? "this Mac"). The default is in Settings on the Macs screen.")
                }
            }
            .navigationTitle("Scroll speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                custom = session.scrollSpeedOverride != nil
                speed = session.scrollSpeedOverride ?? VNCSession.globalScrollSpeed
            }
        }
        .presentationDetents([.medium])
    }

    private func apply() { coordinator.setScrollSpeed(custom ? speed : nil) }
}
