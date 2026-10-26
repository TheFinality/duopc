import SwiftUI

/// App settings. Values live in UserDefaults; sessions read them when they start.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultInputMode") private var inputMode = InputMode.trackpad.rawValue
    @AppStorage("scrollSpeed") private var scrollSpeed = VNCSession.defaultScrollSpeed
    @AppStorage("invertScroll") private var invertScroll = false
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
                        Text("Used for new connections. Each Mac can have its own speed: ••• → Scroll speed while connected.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Open the text box when you click into text", isOn: $autoCompose)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Natural scrolling moves content with your finger. Changes apply to the next connection.")
                }

                Section("Privacy") {
                    Label("Passwords stay in this \(AppInfo.device)'s Keychain.", systemImage: "key.fill")
                    Label("Connections go straight to your Macs.", systemImage: "arrow.left.arrow.right")
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
