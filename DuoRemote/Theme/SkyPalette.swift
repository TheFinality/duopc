import SwiftUI

/// A plain RGB triple so palette maths is testable.
struct SkyRGB: Equatable {
    var r: Double, g: Double, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    func mixed(with o: SkyRGB, _ t: Double) -> SkyRGB {
        SkyRGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// The colours of one moment of the sky.
struct SkyColors: Equatable {
    var rim: [SkyRGB]      // 3 stops
    var label: SkyRGB
    var stars: Double

    func mixed(with o: SkyColors, _ t: Double) -> SkyColors {
        SkyColors(rim: zip(rim, o.rim).map { $0.mixed(with: $1, t) },
                  label: label.mixed(with: o.label, t),
                  stars: stars + (o.stars - stars) * t)
    }
}

/// Palette keyframes, interpolated by solar elevation.
enum SkyKeyframes {
    static let night = SkyColors(rim: [SkyRGB(0x9aa1b4), SkyRGB(0xe4e7f0), SkyRGB(0x7b8296)], label: SkyRGB(0xeef0f6), stars: 1)
    static let blueHour = SkyColors(rim: [SkyRGB(0x2747d6), SkyRGB(0x7a4fe0), SkyRGB(0xd36ad8)], label: SkyRGB(0xe9ebff), stars: 0.4)
    static let sunrise = SkyColors(rim: [SkyRGB(0xff6a3d), SkyRGB(0xff4f8b), SkyRGB(0xffb347)], label: SkyRGB(0xfff0e6), stars: 0)
    static let sunset = SkyColors(rim: [SkyRGB(0xff8a3d), SkyRGB(0xff3f7a), SkyRGB(0x8a3fd8)], label: SkyRGB(0xfff0e6), stars: 0)
    static let morning = SkyColors(rim: [SkyRGB(0xffd36e), SkyRGB(0x7fd8ff), SkyRGB(0x4aa8ff)], label: SkyRGB(0xfff8e3), stars: 0)
    static let midday = SkyColors(rim: [SkyRGB(0x2fb8ff), SkyRGB(0x7fe6ff), SkyRGB(0xd9fbff)], label: SkyRGB(0xeafcff), stars: 0)
    /// Effects off (the ☀/☾ button): quiet greys, a touch lighter than the night palette.
    static let grey = SkyColors(rim: [SkyRGB(0xb4b9c6), SkyRGB(0xd9dce4), SkyRGB(0xa3a9b8)], label: SkyRGB(0xf2f3f7), stars: 0)
    /// "Follow the sky" off: cyan to violet to pink.
    static let neutral = SkyColors(rim: [SkyRGB(0x22d3ee), SkyRGB(0x8b5cf6), SkyRGB(0xec4899)], label: SkyRGB(0xf1f1f8), stars: 0)

    static func colors(elevation e: Double, rising: Bool) -> SkyColors {
        let frames: [(Double, SkyColors)] = [
            (-12, night), (-5, blueHour), (2, rising ? sunrise : sunset), (28, morning), (50, midday)
        ]
        if e <= frames[0].0 { return frames[0].1 }
        if e >= frames[frames.count - 1].0 { return frames[frames.count - 1].1 }
        for i in 1..<frames.count where e <= frames[i].0 {
            let (e0, c0) = frames[i - 1], (e1, c1) = frames[i]
            if e == e1 { return c1 }
            return c0.mixed(with: c1, (e - e0) / (e1 - e0))
        }
        return midday
    }

    static func phaseName(elevation e: Double, rising: Bool) -> String {
        switch e {
        case ..<(-12): "night"
        case ..<(-4): "twilight"
        case ..<6: rising ? "sunrise" : "sunset"
        case ..<40: rising ? "morning" : "afternoon"
        default: "midday"
        }
    }
}

/// The live sky theme: refreshed once a minute, and whenever the relevant settings change.
/// Settings (UserDefaults, a missing key counts as on): `skyTheme`, `effectsEnabled`.
@Observable
final class SkyTheme {
    static let shared = SkyTheme()

    private struct State: Equatable {
        var elevation = 30.0
        var rising = false
        var follow = true
        var effectsToggle = true
        var reduceMotion = false
        var lowPower = false
    }

    private var state = State()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []   // live for the app's lifetime

    init() { refresh() }

    // MARK: Palette

    private var colors: SkyColors {
        if !state.effectsToggle { return SkyKeyframes.grey }
        return state.follow ? SkyKeyframes.colors(elevation: state.elevation, rising: state.rising) : SkyKeyframes.neutral
    }

    var rim: [Color] { colors.rim.map(\.color) }
    var keyAccent: Color { colors.rim[0].color }
    var navAccent: Color { colors.rim[1].color }
    var arrowAccent: Color { colors.rim[2].color }
    var deckTint: Color { colors.rim[1].color.opacity(0.10) }
    var labelColor: Color { colors.label.color }
    var isNight: Bool { state.follow && state.elevation < -6 }
    var starAmount: Double { state.follow ? colors.stars : 0 }

    var elevation: Double { state.elevation }
    var following: Bool { state.follow }
    var phaseName: String { SkyKeyframes.phaseName(elevation: state.elevation, rising: state.rising) }
    /// Animations allowed: the Effects toggle is on, Reduce Motion is off and Low Power Mode is off.
    var motion: Bool { state.effectsToggle && !state.reduceMotion && !state.lowPower }
    /// The Effects toggle itself (the ☀/☾ button): off = plain deck, no glow, stars or sparkles.
    var effectsOn: Bool { state.effectsToggle }

    // MARK: Updating

    func refresh(now: Date = .now) {
        let place = SkyLocation.estimate(at: now)
        var elevation = SunPosition.elevation(at: now, latitude: place.latitude, longitude: place.longitude)
        var rising = SunPosition.isRising(at: now, latitude: place.latitude, longitude: place.longitude)
        #if DEBUG
        // `-skyElevation <deg>` (parsed by hand: UserDefaults mistakes a negative value for a flag).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-skyElevation"), i + 1 < args.count, let e = Double(args[i + 1]) {
            elevation = e
            rising = args.contains("-skyRising")
        }
        #endif
        let defaults = UserDefaults.standard
        let new = State(
            elevation: elevation, rising: rising,
            follow: defaults.object(forKey: "skyTheme") == nil ? true : defaults.bool(forKey: "skyTheme"),
            effectsToggle: defaults.object(forKey: "effectsEnabled") == nil ? true : defaults.bool(forKey: "effectsEnabled"),
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if new != state { state = new }
    }

    /// Starts the once-a-minute refresh and listens for setting changes. Safe to call repeatedly.
    func start() {
        guard task == nil else { return }
        refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refresh()
            }
        }
        let names: [Notification.Name] = [
            UserDefaults.didChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification,
            .NSProcessInfoPowerStateDidChange, UIApplication.significantTimeChangeNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
}

/// Which palette colour outlines a key.
enum SkyAccent {
    case key, nav, arrow

    var color: Color {
        let t = SkyTheme.shared
        switch self {
        case .key: return t.keyAccent
        case .nav: return t.navAccent
        case .arrow: return t.arrowAccent
        }
    }
}
