@preconcurrency import RoyalVNCKit
import Foundation
import Observation

enum InputMode: String, CaseIterable, Identifiable {
    case trackpad, direct
    var id: String { rawValue }
}

enum Modifier: CaseIterable, Hashable {
    case command, option, control, shift

    var keyCode: VNCKeyCode {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }

    var glyph: String {
        switch self { case .command: "⌘"; case .option: "⌥"; case .control: "⌃"; case .shift: "⇧" }
    }

    var name: String {
        switch self { case .command: "Command"; case .option: "Option"; case .control: "Control"; case .shift: "Shift" }
    }
}

/// Sticky modifiers driven by the key bar. A latched modifier applies to the next key press or
/// click and then clears; a locked one stays until tapped again.
@Observable
final class ModifierState {
    enum Mode { case off, latched, locked }

    private(set) var mode: [Modifier: Mode] = [:]
    @ObservationIgnored private var lastTap: (modifier: Modifier, time: TimeInterval)?

    func mode(of m: Modifier) -> Mode { mode[m] ?? .off }

    /// off → latched; latched or locked → off.
    func tap(_ m: Modifier) {
        mode[m] = mode(of: m) == .off ? .latched : .off
    }

    /// → locked.
    func lock(_ m: Modifier) {
        mode[m] = .locked
    }

    /// A tap on a modifier key: a double-tap locks it, a single tap toggles it.
    func keyTapped(_ m: Modifier, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch ModifierTap.decide(previous: lastTap, modifier: m, now: now) {
        case .tap:
            tap(m)
            lastTap = (m, now)
        case .lock:
            lock(m)
            lastTap = nil
        }
    }

    /// The active modifiers' key codes, in a stable order. Clears the latched ones.
    /// Core calls this around each key press or click.
    func consume() -> [VNCKeyCode] {
        let active = Modifier.allCases.filter { mode(of: $0) != .off }
        for m in active where mode(of: m) == .latched { mode[m] = .off }
        return active.map(\.keyCode)
    }

    func reset() { mode = [:] }
}
