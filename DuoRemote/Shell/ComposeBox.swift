import SwiftUI

/// A real iOS text field above the key bar: dictation, autocorrect, emoji, editing.
/// The keyboard's Return key types the text into the Mac and presses Return; the ↑ button types
/// it without Return. Either way the box clears. The lock switches to hidden entry for passwords.
struct ComposeBox: View {
    let session: VNCSession
    @Binding var isShown: Bool
    @State private var text = ""
    @State private var secure = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button("Close", systemImage: "xmark") {
                withAnimation(.snappy) { isShown = false }
            }
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)

            Group {
                if secure {
                    // No autocorrect, prediction, smart punctuation or Passwords autofill: nothing
                    // typed here is learned or suggested later.
                    SecureField("Password", text: $text)
                        .textContentType(nil)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .onSubmit { send(pressReturn: true) }
                } else {
                    TextField("Type or dictate…", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .onChange(of: text) { _, new in
                            // A multi-line field inserts "\n" for the Return key: treat it as send + Return.
                            guard new.contains("\n") else { return }
                            text = new.replacingOccurrences(of: "\n", with: "")
                            send(pressReturn: true)
                        }
                }
            }
            .focused($focused)
            .submitLabel(.send)
            .padding(.vertical, 8)

            Button(secure ? "Show typing" : "Hide typing (for passwords)",
                   systemImage: secure ? "lock.fill" : "lock.open") {
                secure.toggle()
                DispatchQueue.main.async { focused = true }   // the field was replaced
            }
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)

            Button("Send without Return", systemImage: "arrow.up.circle.fill") { send(pressReturn: false) }
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 36, height: 36)
                .disabled(text.isEmpty)
        }
        .padding(.horizontal, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 8)
        .onAppear { focused = true }
    }

    private func send(pressReturn: Bool) {
        guard !text.isEmpty || pressReturn else { return }
        session.typeRaw(pressReturn ? text + "\n" : text)
        // Dictation keeps its own copy of the text and writes it back if the box is cleared
        // while it's still running. End it by dropping focus, clear, then refocus and clear again.
        focused = false
        text = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            text = ""
            focused = true
        }
    }
}
