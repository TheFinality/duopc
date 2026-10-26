import SwiftUI
import UIKit
import VisionKit

/// Mac → iPhone copy without the Mac's help: a snapshot of what's on screen, with iOS Live Text
/// so you can select text natively (or copy all of it). Recognition runs on the phone.
struct LiveTextSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var transcript = ""
    @State private var found: Bool?
    @State private var copied = false
    @State private var showIntro = false
    @AppStorage("copyTextTipsHidden") private var tipsHidden = false

    var body: some View {
        NavigationStack {
            LiveTextImageView(image: image) { analysis in
                transcript = analysis?.transcript ?? ""
                found = !transcript.isEmpty
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !tipsHidden { tips.transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .navigationTitle("Copy text from screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("How it works", systemImage: "questionmark.circle") { showIntro = true }
                }
            }
            .sheet(isPresented: $showIntro) { CopyTextIntro(onContinue: { showIntro = false }, onCancel: nil) }
            .animation(.snappy, value: tipsHidden)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("How to copy", systemImage: "hand.point.up.left").font(.headline)
                Spacer()
                Button("Hide tips") { tipsHidden = true }.font(.subheadline)
            }
            step(1, "Touch and hold a word in the picture below until it highlights.")
            step(2, "Drag the blue handles to cover all the text you want.")
            step(3, "Tap **Copy** in the menu that appears. Or tap **Copy all** at the bottom.")
            Text("Pinch to zoom in on small text. Then paste anywhere on your \(AppInfo.device) as usual.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(.tint))
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Group {
                if !ImageAnalyzer.isSupported {
                    Label("Live Text isn't available on this device", systemImage: "exclamationmark.triangle")
                } else if found == nil {
                    Label("Finding text…", systemImage: "text.viewfinder")
                } else if found == false {
                    Label("No text found. Zoom in on the Mac first, then try again.", systemImage: "eye.slash")
                } else {
                    Label("Text found: touch and hold to select", systemImage: "checkmark.circle")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.setShortLivedText(transcript)
                copied = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(transcript.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// First-time explainer for Copy text from screen (re-openable from the copy screen's ?).
struct CopyTextIntro: View {
    let onContinue: () -> Void
    /// nil = no Cancel button (opened from inside the copy screen).
    let onCancel: (() -> Void)?

    var body: some View {
        // Scrolls, and every line wraps in full: on the Duo's narrow outer display the sheet is
        // short, and a plain VStack truncated each line.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 8)
                wrapped(Text("Copy text from your Mac's screen").font(.title2.bold()))
                wrapped(Text("macOS doesn't share its clipboard with other screen-sharing apps, so instead this takes a picture of what's on your Mac's screen and lets you pick out the text, using Live Text on your \(AppInfo.device).")
                    .foregroundStyle(.secondary))
                VStack(alignment: .leading, spacing: 12) {
                    row("camera.viewfinder", "Takes a snapshot of the part of the Mac's screen you can see now.")
                    row("hand.point.up.left", "Touch and hold to select text, or copy all of it.")
                    row("doc.on.clipboard", "Then paste it anywhere on your \(AppInfo.device).")
                    row("lock.shield", "Everything happens on your \(AppInfo.device). Nothing is sent anywhere.")
                }
                wrapped(Text("Tip: zoom in on the Mac first if the text is small.")
                    .font(.footnote).foregroundStyle(.secondary))
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: onContinue) {
                    Text(onCancel == nil ? "Got it" : "Continue").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .presentationDetents([.large])
    }

    private func wrapped(_ text: some View) -> some View {
        text.fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Zoomable image with Live Text text selection.
private struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage
    let onAnalysis: (ImageAnalysis?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .black
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = imageView

        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .textSelection
        imageView.addInteraction(interaction)
        if ImageAnalyzer.isSupported {
            Task { @MainActor in
                let analyzer = ImageAnalyzer()
                let analysis = try? await analyzer.analyze(image, configuration: .init([.text]))
                interaction.analysis = analysis
                interaction.preferredInteractionTypes = .textSelection
                onAnalysis(analysis)
            }
        } else {
            onAnalysis(nil)
        }
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
