import CoreLocation
import Foundation

struct LocationCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    var coreLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func isSamePosition(as other: LocationCoordinate) -> Bool {
        abs(latitude - other.latitude) < 0.000_001
            && abs(longitude - other.longitude) < 0.000_001
    }
}
