@preconcurrency import RoyalVNCKit
import SwiftUI

/// ⌘ ⌥ ⌃ ⇧ (sticky), Esc, Tab, arrows, keyboard toggle, plus a trailing accessory slot.
/// The modifier and navigation groups are separate views so the shell can split them (e.g. around a fold).
struct KeyBar<Accessory: View>: View {
    let session: VNCSession
    @Binding var keyboardShown: Bool
    let accessory: Accessory

    init(session: VNCSession, keyboardShown: Binding<Bool>, @ViewBuilder accessory: () -> Accessory) {
        self.session = session
        self._keyboardShown = keyboardShown
        self.accessory = accessory()
    }

    @State private var width: CGFloat = 0

    /// Below this width the controls move to a second row so the keys keep the full width.
    private let twoRowWidth: CGFloat = 600

    var body: some View {
        Group {
            if width > 0 && width < twoRowWidth {
                VStack(spacing: 4) {
                    keys
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        controls
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    keys
                    controls.padding(.trailing, 8)
                }
                .frame(minHeight: 52)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var keys: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    KeyBarModifierKeys(session: session)
                    KeyBarMouseKeys(session: session)
                    KeyBarNavigationKeys(session: session)
                }
                .padding(.horizontal, 8)
            }
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)   // a horizontal ScrollView is greedy vertically
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                KeyBarKeyboardToggle(shown: $keyboardShown)
                accessory
            }
        }
    }
}

// MARK: - Groups

/// ⌘ ⌥ ⌃ ⇧. Tap = latch; double-tap = lock; tap again = off.
struct KeyBarModifierKeys: View {
    let session: VNCSession
    @State private var haptic = 0

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Modifier.allCases, id: \.self) { modifier in
                let mode = session.modifiers.mode(of: modifier)
                Button {
                    haptic += 1
                    session.modifiers.keyTapped(modifier)
                } label: {
                    KeyCap(label: Text(modifier.glyph), state: mode == .locked ? .locked : mode == .latched ? .latched : .off, accent: .key)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(modifier.name)
                .accessibilityValue(mode == .locked ? "Locked" : mode == .latched ? "On" : "Off")
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: haptic)
    }
}

/// Esc, Tab, ← ↑ ↓ →. Arrows repeat while held.
struct KeyBarNavigationKeys: View {
    let session: VNCSession

    var body: some View {
        HStack(spacing: 8) {
            RepeatingKey(session: session, key: .escape, repeats: false, name: "Escape") { Text("esc").font(.callout.weight(.medium)) }
            RepeatingKey(session: session, key: .tab, repeats: false, name: "Tab") { Image(systemName: "arrow.right.to.line") }
            RepeatingKey(session: session, key: .delete, repeats: true, name: "Delete") { Image(systemName: "delete.left") }
            RepeatingKey(session: session, key: .leftArrow, repeats: true, name: "Left", accent: .arrow) { Image(systemName: "arrow.left") }
            RepeatingKey(session: session, key: .upArrow, repeats: true, name: "Up", accent: .arrow) { Image(systemName: "arrow.up") }
            RepeatingKey(session: session, key: .downArrow, repeats: true, name: "Down", accent: .arrow) { Image(systemName: "arrow.down") }
            RepeatingKey(session: session, key: .rightArrow, repeats: true, name: "Right", accent: .arrow) { Image(systemName: "arrow.right") }
        }
    }
}

/// Right click at the pointer (as well as the two-finger tap).
struct KeyBarMouseKeys: View {
    let session: VNCSession
    @State private var haptic = 0

    var body: some View {
        Button {
            haptic += 1
            session.click(.right)
        } label: {
            KeyCap(label: Image(systemName: "contextualmenu.and.cursorarrow"), state: .off, accent: .nav)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: haptic)
        .accessibilityLabel("Right click")
    }
}

struct KeyBarKeyboardToggle: View {
    @Binding var shown: Bool
    @State private var haptic = 0

    var body: some View {
        Button {
            haptic += 1
            shown.toggle()
        } label: {
            KeyCap(label: Image(systemName: shown ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.title2)
                        .frame(minWidth: 52, minHeight: 44),
                   state: shown ? .latched : .off, accent: .nav)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: haptic)
        .accessibilityLabel(shown ? "Hide keyboard" : "Show keyboard")
    }
}

// MARK: - Pieces

private struct KeyCap<Label: View>: View {
    enum KeyState { case off, latched, locked }
    let label: Label
    let state: KeyState
    var accent: SkyAccent = .nav

    var body: some View {
        label
            .font(.title3)
            .foregroundStyle(state == .locked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(minWidth: 44, minHeight: 44)
            .overlay(alignment: .bottom) {
                if state == .locked {
                    Capsule().fill(.white).frame(width: 18, height: 3).padding(.bottom, 5)
                }
            }
            .glassEffect(glass, in: .rect(cornerRadius: 14))
            .overlay {
                // A light sky-coloured outline; the glass stays the main surface.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.color.opacity(0.4), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: 14))
    }

    private var glass: Glass {
        switch state {
        case .off: .regular.interactive()
        case .latched: .regular.tint(.accentColor.opacity(0.45)).interactive()
        case .locked: .regular.tint(.accentColor).interactive()
        }
    }
}

/// Fires on press-down; `repeats` keys auto-repeat while held.
private struct RepeatingKey<Label: View>: View {
    let session: VNCSession
    let key: VNCKeyCode
    let repeats: Bool
    let name: String
    var accent: SkyAccent = .nav
    @ViewBuilder let label: Label
    @State private var repeater = KeyRepeater()
    @State private var haptic = 0

    var body: some View {
        Button {} label: {
            KeyCap(label: label, state: .off, accent: accent)
        }
        .buttonStyle(PressReportingStyle { pressed in
            if pressed {
                haptic += 1
                repeater.begin(repeats: repeats) { [session, key] in session.press(key) }
            } else {
                repeater.end()
            }
        })
        .sensoryFeedback(.impact(weight: .light), trigger: haptic)
        .accessibilityLabel(name)
        .onDisappear { repeater.end() }
    }
}

private struct PressReportingStyle: ButtonStyle {
    let onChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onChange(pressed) }
    }
}
