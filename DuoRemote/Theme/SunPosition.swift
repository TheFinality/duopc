import Foundation

/// Solar elevation from a date and a place (NOAA-style low-precision approximation, good to
/// about a degree — plenty for choosing colours).
enum SunPosition {
    /// Elevation of the sun's centre above the horizon, in degrees (negative = below).
    /// `longitude` is east-positive degrees.
    static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = jd - 2451545.0
        let rad = Double.pi / 180
        let meanLon = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let anomaly = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let eclipticLon = (meanLon + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let declination = asin(sin(obliquity) * sin(eclipticLon))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLon), cos(eclipticLon))
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360) * rad
        let hourAngle = gmst + longitude * rad - rightAscension
        let lat = latitude * rad
        let sinElevation = sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)
        return asin(max(-1, min(1, sinElevation))) / rad
    }

    /// True while the sun is climbing (looks ten minutes ahead).
    static func isRising(at date: Date, latitude: Double, longitude: Double) -> Bool {
        elevation(at: date.addingTimeInterval(600), latitude: latitude, longitude: longitude)
            > elevation(at: date, latitude: latitude, longitude: longitude)
    }
}
