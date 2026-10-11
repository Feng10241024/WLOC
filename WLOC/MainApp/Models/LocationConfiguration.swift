import Foundation

struct LocationConfiguration: Codable, Equatable, Sendable {
    let longitude: Double
    let latitude: Double
    let accuracy: Double

    var isValid: Bool {
        Self.isValid(longitude: longitude, latitude: latitude, accuracy: accuracy)
    }

    static func isValid(longitude: Double, latitude: Double, accuracy: Double) -> Bool {
        longitude.isFinite
            && latitude.isFinite
            && accuracy.isFinite
            && (-180.0...180.0).contains(longitude)
            && (-90.0...90.0).contains(latitude)
            && accuracy > 0
    }
}
