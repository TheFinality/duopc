import AVFoundation
import PhotosUI
import SwiftUI

/// App settings. Values live in UserDefaults; sessions read them when they start.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultInputMode") private var inputMode = InputMode.trackpad.rawValue
    @AppStorage("scrollSpeed") private var scrollSpeed = VNCSession.defaultScrollSpeed
    @AppStorage("invertScroll") private var invertScroll = false
    @AppStorage(PictureQuality.storageKey) private var pictureQuality: PictureQuality = .balanced
    @AppStorage("pcSound") private var pcSound = true
    @AppStorage("autoQuality") private var autoQuality = true
    @AppStorage("showConnectionInfo") private var showConnectionInfo = false
    @AppStorage("keyHaptics") private var keyHaptics = true
    @AppStorage("laptopScreenClicks") private var laptopScreenClicks = false
    @AppStorage("autoCompose") private var autoCompose = true
    @AppStorage("effectsEnabled") private var effectsEnabled = true
    @AppStorage("skyTheme") private var skyTheme = true

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Look and feel") {
                    Toggle(isOn: $effectsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Effects")
                            Text("Animations, sparkles and screen effects").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $skyTheme) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Follow the sky")
                            Text("Colours change with the time of day where you are").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    SkyPreview()
                }

                Section {
                    Picker("Default input mode", selection: $inputMode) {
                        Text("Trackpad").tag(InputMode.trackpad.rawValue)
                        Text("Direct touch").tag(InputMode.direct.rawValue)
                    }
                    Toggle("Natural scrolling", isOn: Binding(get: { !invertScroll }, set: { invertScroll = !$0 }))
                    VStack(alignment: .leading) {
                        Text("Default scroll speed: \(scrollSpeed, format: .number.precision(.fractionLength(1)))×")
                        Slider(value: $scrollSpeed, in: 1...5, step: 0.25)
                        Text("Used for new connections. Each PC can have its own speed: ••• → Scroll speed while connected.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Click on the screen in laptop pose", isOn: $laptopScreenClicks)
                    Toggle("Open the text box when you click into text", isOn: $autoCompose)
                    Toggle("Haptic feedback when typing", isOn: $keyHaptics)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Natural scrolling moves content with your finger. Changes apply to the next connection. In laptop pose the screen half is for looking: drag to move around when zoomed in, pinch to zoom, two fingers to scroll. Turn on clicking there to use it like the trackpad (or direct touch). Typing haptics are a firm tap per key on the keyboard; if you also feel iOS's own keyboard haptics (Settings → Sounds & Haptics → Keyboard Feedback), turn one of them off.")
                }

                Section {
                    Picker("Picture quality", selection: $pictureQuality) {
                        ForEach(PictureQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Automatic quality", isOn: $autoQuality)
                    Toggle("PC sound", isOn: $pcSound)
                    Toggle("Connection info", isOn: $showConnectionInfo)
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Fast sends a softer picture while things move, which keeps up better over mobile data or a slow home upload. Text sharpens once it stops changing. With video streaming, automatic quality lowers it for you while the network can't keep up and brings it back after; PC sound plays what the PC is playing; connection info shows the delay, frame rate and data rate in a corner, amber while the network is backing up. You can also switch these while connected, in the ••• menu.")
                }

                OuterPictureSection()

                Section("Privacy") {
                    Label("Passwords stay in this \(AppInfo.device)'s Keychain.", systemImage: "key.fill")
                    Label("Connections go straight to your PCs.", systemImage: "arrow.left.arrow.right")
                    Label("No accounts, no analytics and no servers.", systemImage: "hand.raised.fill")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// Choose the picture for the outer screen, and turn it on and off.
private struct OuterPictureSection: View {
    @AppStorage(OuterPicture.enabledKey) private var enabled = false
    @AppStorage(OuterPicture.versionKey) private var version = 0
    @State private var picked: PhotosPickerItem?
    @State private var thumbnail: UIImage?
    @State private var cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied
    @State private var failed = false

    var body: some View {
        Section {
            Toggle("Picture on the outer screen", isOn: $enabled)
                .disabled(version == 0)
            PhotosPicker(selection: $picked, matching: .images) {
                Label(version == 0 ? "Choose picture" : "Change picture", systemImage: "photo.on.rectangle")
            }
            if let thumbnail {
                HStack {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 96)
                        .clipShape(.rect(cornerRadius: 8))
                    Spacer()
                    Button("Remove", role: .destructive) {
                        OuterPicture.remove()
                        enabled = false
                        version = 0
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Outer screen")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("While you're connected with the phone unfolded, the outer screen (the back of the lid in laptop pose) shows this picture. iOS only allows that while the camera is on, so the camera runs at its lowest setting and the green camera dot shows; nothing it sees is kept or sent. It uses a little more battery.")
                if cameraDenied {
                    Text("Camera access is off for DuoPC: turn it on in Settings → Privacy & Security → Camera.")
                        .foregroundStyle(.orange)
                }
                if failed {
                    Text("That picture couldn't be read. Try another.").foregroundStyle(.orange)
                }
            }
        }
        .task(id: version) { thumbnail = version > 0 ? OuterPicture.load() : nil }
        .onChange(of: enabled) { _, on in
            guard on else { return }
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraDenied = !granted
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                picked = nil
                let data = try? await item.loadTransferable(type: Data.self)
                let jpeg = await Task.detached { data.flatMap { OuterPicture.prepare($0) } }.value
                guard let jpeg, (try? OuterPicture.save(jpeg)) != nil else { failed = true; return }
                failed = false
                version += 1
                enabled = true
            }
        }
    }
}

/// A live swatch of the current palette and the sun's elevation, e.g. "Sun 14° · afternoon".
private struct SkyPreview: View {
    var body: some View {
        let t = SkyTheme.shared
        HStack(spacing: 12) {
            Capsule()
                .fill(LinearGradient(colors: t.rim, startPoint: .leading, endPoint: .trailing))
                .frame(width: 72, height: 14)
                .shadow(color: t.rim[1].opacity(0.6), radius: 5)
            Text(t.following ? "Sun \(Int(t.elevation.rounded()))° · \(t.phaseName)" : "Fixed neon palette")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Third-party licences, which must ship with every build (Acknowledgements.txt).
private struct AcknowledgementsView: View {
    private let text = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
