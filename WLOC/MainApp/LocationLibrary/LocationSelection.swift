import CoreLocation
import Foundation

/// A candidate to browse or save. Selecting it does not change the VPN location.
struct LocationSelection: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var address: String?
    let coordinateWGS84: LocationCoordinate
    let accuracy: Double

    init(id: UUID = UUID(), name: String, address: String? = nil,
         coordinateWGS84: LocationCoordinate, accuracy: Double) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinateWGS84 = coordinateWGS84
        self.accuracy = accuracy
    }

    var displayCoordinate: LocationCoordinate {
        let coordinate = ChinaMapCoordinateConverter.gcj02(fromWGS84: coordinateWGS84.coreLocationCoordinate)
        return LocationCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinateText: String {
        String(format: "经度 %.6f · 纬度 %.6f", displayCoordinate.longitude, displayCoordinate.latitude)
    }

    static func searchResult(_ result: PlaceSearchResult, accuracy: Double) -> Self {
        let wgs84 = ChinaMapCoordinateConverter.wgs84(fromGCJ02: result.mapCoordinate.coreLocationCoordinate)
        return Self(name: result.name, address: result.address,
            coordinateWGS84: LocationCoordinate(latitude: wgs84.latitude, longitude: wgs84.longitude),
            accuracy: accuracy)
    }

    static func favorite(_ favorite: FavoriteLocation, fallbackAccuracy: Double) -> Self {
        Self(name: favorite.name, address: favorite.address,
            coordinateWGS84: favorite.coordinateWGS84,
            accuracy: favorite.accuracy ?? fallbackAccuracy)
    }

    static func manual(longitude: String, latitude: String, accuracy: String,
                       name: String = "") throws -> Self {
        guard let longitude = parseNumber(longitude), let latitude = parseNumber(latitude),
              let accuracy = parseNumber(accuracy) else {
            throw LocationInputError.invalidNumber
        }
        let display = LocationCoordinate(latitude: latitude, longitude: longitude)
        guard display.isValid else { throw LocationInputError.invalidCoordinate }
        guard accuracy.isFinite && accuracy > 0 else { throw LocationInputError.invalidAccuracy }
        let coordinate = ChinaMapCoordinateConverter.wgs84(fromGCJ02: display.coreLocationCoordinate)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(name: trimmedName.isEmpty ? "坐标位置" : trimmedName,
            coordinateWGS84: LocationCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
            accuracy: accuracy)
    }

    private static func parseNumber(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}

enum LocationInputError: LocalizedError {
    case invalidNumber, invalidCoordinate, invalidAccuracy
    var errorDescription: String? {
        switch self {
        case .invalidNumber: "请输入有效的经度、纬度和精度"
        case .invalidCoordinate: "经度应在 -180 到 180 之间，纬度应在 -90 到 90 之间"
        case .invalidAccuracy: "精度必须是大于 0 的有效数字（米）"
        }
    }
}
