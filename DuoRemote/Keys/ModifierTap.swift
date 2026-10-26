import Foundation

/// Single tap vs double-tap on a modifier key. Pure, so it can be tested with injected timestamps.
enum ModifierTap {
    enum Decision: Equatable { case tap, lock }

    static let doubleTapWindow: TimeInterval = 0.3

    /// `previous` is the last tap on any modifier key (nil once consumed by a lock).
    static func decide(previous: (modifier: Modifier, time: TimeInterval)?,
                       modifier: Modifier,
                       now: TimeInterval,
                       window: TimeInterval = doubleTapWindow) -> Decision {
        if let previous, previous.modifier == modifier, now - previous.time <= window {
            return .lock
        }
        return .tap
    }
}
