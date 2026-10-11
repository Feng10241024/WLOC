import Foundation

struct FavoriteLocation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let coordinateWGS84: LocationCoordinate
    let address: String?
    let accuracy: Double?

    init(
        id: UUID = UUID(),
        name: String,
        coordinateWGS84: LocationCoordinate,
        address: String? = nil,
        accuracy: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinateWGS84 = coordinateWGS84
        self.address = address
        self.accuracy = accuracy
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && coordinateWGS84.isValid
            && (accuracy.map { $0.isFinite && $0 > 0 } ?? true)
    }
}
