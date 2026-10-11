import CoreLocation

/// Adapts WGS-84 coordinates used by Core Location and WLOC to the GCJ-02
/// coordinate space used by mainland China map data. Conversion belongs only
/// at the map UI boundary; persisted and rewritten coordinates remain WGS-84.
enum ChinaMapCoordinateConverter {
    nonisolated private static let semiMajorAxis = 6_378_245.0
    nonisolated private static let eccentricitySquared = 0.00669342162296594323

    nonisolated static func gcj02(fromWGS84 coordinate: CLLocationCoordinate2D)
        -> CLLocationCoordinate2D {
        guard requiresChinaMapOffset(coordinate) else {
            return coordinate
        }

        let longitudeOffset = coordinate.longitude - 105
        let latitudeOffset = coordinate.latitude - 35
        var latitudeDelta = transformLatitude(
            longitude: longitudeOffset,
            latitude: latitudeOffset
        )
        var longitudeDelta = transformLongitude(
            longitude: longitudeOffset,
            latitude: latitudeOffset
        )
        let latitudeRadians = coordinate.latitude / 180 * .pi
        let latitudeSine = sin(latitudeRadians)
        let magic = 1 - eccentricitySquared * latitudeSine * latitudeSine
        let squareRootMagic = sqrt(magic)
        latitudeDelta = latitudeDelta * 180
            / ((semiMajorAxis * (1 - eccentricitySquared))
                / (magic * squareRootMagic) * .pi)
        longitudeDelta = longitudeDelta * 180
            / (semiMajorAxis / squareRootMagic
                * cos(latitudeRadians) * .pi)

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeDelta,
            longitude: coordinate.longitude + longitudeDelta
        )
    }

    nonisolated static func wgs84(fromGCJ02 coordinate: CLLocationCoordinate2D)
        -> CLLocationCoordinate2D {
        guard requiresChinaMapOffset(coordinate) else {
            return coordinate
        }

        // GCJ-02 has no simple closed-form inverse. Iteratively remove the
        // forward-transform delta so map selections round-trip accurately.
        var estimate = coordinate
        for _ in 0..<6 {
            let converted = gcj02(fromWGS84: estimate)
            let latitudeError = converted.latitude - coordinate.latitude
            let longitudeError = converted.longitude - coordinate.longitude
            estimate = CLLocationCoordinate2D(
                latitude: estimate.latitude - latitudeError,
                longitude: estimate.longitude - longitudeError
            )
            if abs(latitudeError) < 0.000_000_01,
               abs(longitudeError) < 0.000_000_01 {
                break
            }
        }
        return estimate
    }

    nonisolated private static func requiresChinaMapOffset(
        _ coordinate: CLLocationCoordinate2D
    ) -> Bool {
        (72.004...137.8347).contains(coordinate.longitude)
            && (0.8293...55.8271).contains(coordinate.latitude)
    }

    nonisolated private static func transformLatitude(
        longitude: Double,
        latitude: Double
    ) -> Double {
        var value = -100 + 2 * longitude + 3 * latitude
            + 0.2 * latitude * latitude
            + 0.1 * longitude * latitude
            + 0.2 * sqrt(abs(longitude))
        value += (20 * sin(6 * longitude * .pi)
            + 20 * sin(2 * longitude * .pi)) * 2 / 3
        value += (20 * sin(latitude * .pi)
            + 40 * sin(latitude / 3 * .pi)) * 2 / 3
        value += (160 * sin(latitude / 12 * .pi)
            + 320 * sin(latitude / 30 * .pi)) * 2 / 3
        return value
    }

    nonisolated private static func transformLongitude(
        longitude: Double,
        latitude: Double
    ) -> Double {
        var value = 300 + longitude + 2 * latitude
            + 0.1 * longitude * longitude
            + 0.1 * longitude * latitude
            + 0.1 * sqrt(abs(longitude))
        value += (20 * sin(6 * longitude * .pi)
            + 20 * sin(2 * longitude * .pi)) * 2 / 3
        value += (20 * sin(longitude * .pi)
            + 40 * sin(longitude / 3 * .pi)) * 2 / 3
        value += (150 * sin(longitude / 12 * .pi)
            + 300 * sin(longitude / 30 * .pi)) * 2 / 3
        return value
    }
}
