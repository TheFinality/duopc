@preconcurrency import RoyalVNCKit
import SwiftUI
import UIKit

enum DeckMode: String { case trackpad, keyboard }

/// Laptop pose (Duo half-open, fold horizontal): the Mac screen on the top half, this deck on
/// the bottom. Trackpad mode: modifiers | trackpad + click buttons | Esc/Tab/arrows.
/// Keyboard mode: a key row, with the system keyboard filling the rest of the deck.
struct LaptopDeck: View {
    let session: VNCSession
    let coordinator: SessionCoordinator
    @Binding var mode: DeckMode
    @Binding var keyboardShown: Bool
    @Binding var composeShown: Bool
    var bottomInset: CGFloat = 0
    @State private var touches = TrackpadTouches()

    var body: some View {
        VStack(spacing: 12) {
            deckContent
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, max(bottomInset, 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DeckBackground() }
        .foldLightSweep()
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: mode)
        .onChange(of: mode, initial: true) { _, m in
            keyboardShown = (m == .keyboard)
            if m == .trackpad {
                UIApplication.shared.dismissKeyboard()
            }
        }
    }

    @ViewBuilder private var deckContent: some View {
            header
            if mode == .trackpad {
                trackpadDeck
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                // Keyboard mode: the keys live in LaptopKeyStrip, above the fold, so the
                // keyboard can't cover them. Only this header stays on the deck.
                Spacer(minLength: 0)
            }
    }

    // MARK: Header — tools left, mode switch centre, session right

    private var header: some View {
        // Must fit the folded-out width (~466 pt): "Copy text from screen" lives in the ••• menu.
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    DeckIconButton(systemImage: "doc.on.clipboard", label: "Paste to Mac", action: session.pasteClipboard)
                        .pasteBeamSource()
                    DeckIconButton(systemImage: composeShown ? "text.bubble.fill" : "text.bubble", label: "Text box",
                                   on: composeShown) {
                        withAnimation(.snappy) { composeShown.toggle() }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                SkyGlyph()
                DeckModePicker(mode: $mode) { m in
                    if m == .keyboard { keyboardShown = true }   // re-show even if already selected
                }
            }
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    SessionMenu(session: session, coordinator: coordinator)
                        .frame(width: 38, height: 38)
                        .glassEffect(.regular.interactive(), in: .circle)
                    DeckIconButton(systemImage: "rectangle.portrait.and.arrow.right", label: "Disconnect", tint: .red) {
                        coordinator.disconnect()
                    }
                }
            }
        }
    }

    // MARK: Trackpad mode (layout D)

    private var trackpadDeck: some View {
        // Slim modifier column, a full-height trackpad with click zones along its bottom edge,
        // slim keys on the right.
        HStack(spacing: 10) {
            VStack(spacing: 7) {
                ForEach(Modifier.allCases, id: \.self) { m in
                    DeckModifierKey(session: session, modifier: m)
                }
            }
            .frame(width: 58)

            TrackpadPad(session: session, touches: touches)

            VStack(spacing: 7) {
                DeckKey(label: Text("esc").font(.callout.weight(.medium)), accent: .nav) { session.press(.escape) }
                    .frame(height: 40)
                DeckKey(label: Image(systemName: "arrow.right.to.line"), accent: .nav) { session.press(.tab) }
                    .frame(height: 40)
                DeckKey(label: Image(systemName: "delete.left"), repeats: true, accent: .nav) { session.press(.delete) }
                    .frame(height: 40)
                DeckKey(label: Image(systemName: "return"), accent: .nav) { session.press(.return) }
                    .frame(height: 40)
                Spacer(minLength: 0)
                ArrowCluster(session: session)
            }
            .frame(width: 96)
        }
    }
}

/// Laptop keyboard mode: modifiers and keys in a slim strip along the bottom of the screen
/// half, in the gutter above the fold, where the system keyboard can never cover them.
struct LaptopKeyStrip: View {
    let session: VNCSession

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Modifier.allCases, id: \.self) { m in
                    DeckModifierKey(session: session, modifier: m).frame(width: 50)
                }
                DeckKey(label: Text("esc").font(.callout.weight(.medium)), accent: .nav) { session.press(.escape) }.frame(width: 50)
                DeckKey(label: Image(systemName: "arrow.right.to.line"), accent: .nav) { session.press(.tab) }.frame(width: 50)
                DeckKey(label: Image(systemName: "delete.left"), repeats: true, accent: .nav) { session.press(.delete) }.frame(width: 50)
                ForEach([("arrow.left", VNCKeyCode.leftArrow), ("arrow.up", .upArrow),
                         ("arrow.down", .downArrow), ("arrow.right", .rightArrow)], id: \.0) { icon, key in
                    DeckKey(label: Image(systemName: icon), repeats: true, accent: .arrow) { session.press(key) }.frame(width: 50)
                }
            }
            .frame(height: 42)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                LinearGradient(colors: [Color(white: 0.09), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
                SkyTheme.shared.deckTint
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Pieces

/// Brushed-dark deck with a faint top highlight, like the palm rest of a dark laptop.
private struct DeckBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
            LinearGradient(colors: [SkyTheme.shared.deckTint, .clear], startPoint: .bottom, endPoint: .top)
            StarField()
        }
        .ignoresSafeArea()
    }
}

/// The trackpad: a glassy recessed surface with a fine edge highlight.
private struct TrackpadPad: View {
    let session: VNCSession
    let touches: TrackpadTouches
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        TrackpadSurface(session: session, touches: touches)
            .background {
                shape.fill(Color(red: 0.095, green: 0.1, blue: 0.12))
            }
            .overlay(alignment: .top) {
                Text("tap to click · two fingers to scroll")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                // Click zones, like an old MacBook's button: hold one with a thumb while
                // dragging on the pad with the other finger.
                HStack(spacing: 0) {
                    DeckClickZone(session: session, button: .left, title: "click")
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.vertical, 8)
                    DeckClickZone(session: session, button: .right, title: "right click")
                }
                .frame(height: 44)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.horizontal, 12) }
            }
            .overlay { NeonRim(touches: touches.points, cornerRadius: 20) }
            .clipShape(shape)
    }
}

/// Segmented glass switch with a sliding highlight.
private struct DeckModePicker: View {
    @Binding var mode: DeckMode
    var onSelect: (DeckMode) -> Void = { _ in }
    @Namespace private var ns

    var body: some View {
        // Both segments show labels, or (when narrow) both show icons only.
        ViewThatFits(in: .horizontal) {
            segments(compact: false)
            segments(compact: true)
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func segments(compact: Bool) -> some View {
        HStack(spacing: 2) {
            segment(.trackpad, "Trackpad", "rectangle.and.hand.point.up.left", compact)
            segment(.keyboard, "Keyboard", "keyboard", compact)
        }
    }

    private func segment(_ m: DeckMode, _ title: String, _ icon: String, _ compact: Bool) -> some View {
        Button {
            mode = m
            onSelect(m)
        } label: {
            Group {
                if compact { Image(systemName: icon) } else { Label(title, systemImage: icon).fixedSize() }
            }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .foregroundStyle(mode == m ? .primary : .secondary)
                .background {
                    if mode == m {
                        Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "seg", in: ns)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// A key on the deck: glass, pressable, optional auto-repeat while held.
private struct DeckKey<Label: View>: View {
    let label: Label
    var repeats = false
    var tint: Color? = nil
    var accent: SkyAccent? = nil
    var glow: ModifierState.Mode? = nil
    let action: () -> Void
    @State private var pressed = false
    @State private var repeater = KeyRepeater()

    init(label: Label, repeats: Bool = false, tint: Color? = nil, accent: SkyAccent? = nil,
         glow: ModifierState.Mode? = nil, action: @escaping () -> Void) {
        self.label = label
        self.repeats = repeats
        self.tint = tint
        self.accent = accent
        self.glow = glow
        self.action = action
    }

    var body: some View {
        label
            .font(.title3)
            // Dark face with a sky-coloured outline and label.
            .foregroundStyle(accent?.color ?? SkyTheme.shared.labelColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 34)
            .background {
                let face = RoundedRectangle(cornerRadius: 12, style: .continuous)
                ZStack {
                    face.fill(Color(red: 0.075, green: 0.08, blue: 0.095))
                    if let tint { face.fill(tint.opacity(pressed ? 0.45 : 0.3)) }
                    if pressed { face.fill((accent?.color ?? .white).opacity(0.22)) }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((accent?.color ?? .white).opacity(accent == nil ? 0.18 : 0.85), lineWidth: 1.5)
                    .shadow(color: (accent?.color ?? .clear).opacity(0.45), radius: 4)
                    .allowsHitTesting(false)
            }
            .overlay {
                if let accent, let glow, glow != .off {
                    ModifierGlow(locked: glow == .locked, color: accent.color)
                }
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(duration: 0.18), value: pressed)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    repeater.begin(repeats: repeats, action)
                }
                .onEnded { _ in
                    pressed = false
                    repeater.end()
                })
            .onDisappear { repeater.end() }
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, new in new }
    }
}

/// ⌘ ⌥ ⌃ ⇧ — tap to latch, double-tap to lock, tap again to release. Lit when active.
private struct DeckModifierKey: View {
    let session: VNCSession
    let modifier: Modifier

    var body: some View {
        let state = session.modifiers.mode(of: modifier)
        DeckKey(label: Text(modifier.glyph).font(.title2), tint: state == .off ? nil : SkyTheme.shared.keyAccent.opacity(0.35),
                accent: .key, glow: state) {
            session.modifiers.keyTapped(modifier)
        }
        .accessibilityLabel(modifier.name)
        .overlay(alignment: .bottom) {
            if state == .locked {
                Capsule().fill(.white).frame(width: 16, height: 3).padding(.bottom, 5).allowsHitTesting(false)
            }
        }
    }
}

/// A click zone along the trackpad's bottom edge: press = mouse button down, release = up.
private struct DeckClickZone: View {
    let session: VNCSession
    let button: VNCMouseButton
    let title: String
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(SkyTheme.shared.navAccent.opacity(down ? 1 : 0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if down { Rectangle().fill(SkyTheme.shared.navAccent.opacity(0.18)) } }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    session.buttonDown(button)
                    session.display?.viewportDidChange()
                }
                .onEnded { _ in
                    down = false
                    session.buttonUp(button)
                })
            .sensoryFeedback(.impact(weight: .medium), trigger: down)
            .accessibilityLabel(title)
    }
}

/// Inverted-T arrow keys, like a laptop.
private struct ArrowCluster: View {
    let session: VNCSession

    var body: some View {
        VStack(spacing: 6) {
            DeckKey(label: Image(systemName: "arrowtriangle.up.fill").font(.caption), repeats: true, accent: .arrow) { session.press(.upArrow) }
                .frame(width: 38)
            HStack(spacing: 6) {
                DeckKey(label: Image(systemName: "arrowtriangle.left.fill").font(.caption), repeats: true, accent: .arrow) { session.press(.leftArrow) }
                DeckKey(label: Image(systemName: "arrowtriangle.down.fill").font(.caption), repeats: true, accent: .arrow) { session.press(.downArrow) }
                DeckKey(label: Image(systemName: "arrowtriangle.right.fill").font(.caption), repeats: true, accent: .arrow) { session.press(.rightArrow) }
            }
        }
        .frame(height: 86)
    }
}

private struct DeckIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .white
    /// A toggle that's on: blue glass, white symbol.
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.blue).interactive() : .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// ☀ by day, ☾ at night, next to the mode switch. Tap it to turn all effects on or off.
private struct SkyGlyph: View {
    @AppStorage("effectsEnabled") private var effectsEnabled = true

    var body: some View {
        let t = SkyTheme.shared
        Button {
            effectsEnabled.toggle()
        } label: {
            Image(systemName: t.isNight ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(effectsEnabled ? t.rim[0] : Color.white.opacity(0.35))
                .shadow(color: t.rim[0].opacity(effectsEnabled ? 0.8 : 0), radius: 4)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: effectsEnabled)
        .accessibilityLabel(effectsEnabled ? "Turn effects off" : "Turn effects on")
    }
}
