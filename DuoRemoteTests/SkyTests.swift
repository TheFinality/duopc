import Testing
import Foundation
@testable import DuoRemote

struct SkyTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func londonJuneNoonIsHigh() {
        let e = SunPosition.elevation(at: date("2026-06-21T12:00:00Z"), latitude: 51.5, longitude: 0)
        #expect(e > 60 && e < 64)
    }

    @Test func londonMidnightIsBelowHorizon() {
        #expect(SunPosition.elevation(at: date("2026-06-21T23:30:00Z"), latitude: 51.5, longitude: 0) < 0)
        #expect(SunPosition.elevation(at: date("2026-12-21T00:00:00Z"), latitude: 51.5, longitude: 0) < -30)
    }

    @Test func morningIsRisingAfternoonIsNot() {
        #expect(SunPosition.isRising(at: date("2026-06-21T08:00:00Z"), latitude: 51.5, longitude: 0))
        #expect(!SunPosition.isRising(at: date("2026-06-21T16:00:00Z"), latitude: 51.5, longitude: 0))
    }

    @Test func locationFromZone() {
        let london = TimeZone(identifier: "Europe/London")!
        let summer = date("2026-07-01T12:00:00Z")
        #expect(SkyLocation.longitude(for: london, at: summer) == 0)     // BST removed
        #expect(SkyLocation.latitude(forZoneIdentifier: "Europe/London") == 51.5)
        #expect(SkyLocation.longitude(for: TimeZone(identifier: "America/New_York")!, at: summer) == -75)
        #expect(SkyLocation.latitude(forZoneIdentifier: "Europe/Lisbon") == 50)
        #expect(SkyLocation.latitude(forZoneIdentifier: "Antarctica/Troll") == 45)
    }

    @Test func paletteKeyframes() {
        #expect(SkyKeyframes.colors(elevation: -30, rising: true) == SkyKeyframes.night)
        #expect(SkyKeyframes.colors(elevation: 80, rising: false) == SkyKeyframes.midday)
        #expect(SkyKeyframes.colors(elevation: 2, rising: true) == SkyKeyframes.sunrise)
        #expect(SkyKeyframes.colors(elevation: 2, rising: false) == SkyKeyframes.sunset)
        let mid = SkyKeyframes.colors(elevation: -8.5, rising: true)
        #expect(mid.stars > 0.4 && mid.stars < 1)
        #expect(SkyKeyframes.phaseName(elevation: 14, rising: false) == "afternoon")
    }
}
