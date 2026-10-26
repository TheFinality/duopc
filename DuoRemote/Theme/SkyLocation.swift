import Foundation

/// A rough place on Earth, guessed from the time zone alone. No location permission is asked.
enum SkyLocation {
    struct Place: Equatable { var latitude: Double; var longitude: Double }

    private static let zoneLatitudes: [String: Double] = [
        "Europe/London": 51.5, "Europe/Dublin": 53.3, "Europe/Paris": 48.9, "Europe/Berlin": 52.5,
        "Europe/Madrid": 40.4, "Europe/Rome": 41.9, "Europe/Amsterdam": 52.4, "Europe/Stockholm": 59.3,
        "Europe/Moscow": 55.8, "Atlantic/Reykjavik": 64.1,
        "America/New_York": 40.7, "America/Chicago": 41.9, "America/Denver": 39.7,
        "America/Los_Angeles": 34.1, "America/Toronto": 43.7, "America/Mexico_City": 19.4,
        "America/Sao_Paulo": -23.5, "America/Argentina/Buenos_Aires": -34.6,
        "Asia/Tokyo": 35.7, "Asia/Shanghai": 31.2, "Asia/Singapore": 1.35, "Asia/Kolkata": 19.1,
        "Asia/Dubai": 25.2, "Australia/Sydney": -33.9, "Pacific/Auckland": -36.8,
        "Africa/Johannesburg": -26.2, "Africa/Cairo": 30.0
    ]

    private static let prefixLatitudes: [(String, Double)] = [
        ("Europe/", 50), ("America/", 38), ("Asia/", 30), ("Australia/", -33), ("Africa/", 5), ("Pacific/", -15)
    ]

    static func latitude(forZoneIdentifier id: String) -> Double {
        if let exact = zoneLatitudes[id] { return exact }
        return prefixLatitudes.first { id.hasPrefix($0.0) }?.1 ?? 45
    }

    /// Longitude from the zone's *standard* offset (daylight saving removed), 15° per hour.
    static func longitude(for zone: TimeZone, at date: Date) -> Double {
        let standard = zone.secondsFromGMT(for: date) - Int(zone.daylightSavingTimeOffset(for: date))
        return Double(standard) / 3600 * 15
    }

    static func estimate(zone: TimeZone = .current, at date: Date = .now) -> Place {
        Place(latitude: latitude(forZoneIdentifier: zone.identifier), longitude: longitude(for: zone, at: date))
    }
}
