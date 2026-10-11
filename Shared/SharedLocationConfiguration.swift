import Foundation

struct SharedLocationConfiguration: Codable, Equatable, Sendable {
    let longitude: Double
    let latitude: Double
    let accuracy: Double
    let rewriteEnabled: Bool
    let configurationVersion: Int

    var isValid: Bool {
        (-180.0...180.0).contains(longitude)
            && (-90.0...90.0).contains(latitude)
            && accuracy.isFinite
            && accuracy > 0
            && configurationVersion >= 0
    }
}
