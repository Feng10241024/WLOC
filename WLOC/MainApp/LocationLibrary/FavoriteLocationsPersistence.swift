import Foundation

enum FavoriteLocationError: LocalizedError, Equatable {
    case emptyName
    case invalidCoordinate
    case invalidAccuracy
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: "请输入收藏名称"
        case .invalidCoordinate: "请先选择有效的测试位置"
        case .invalidAccuracy: "精度必须是大于 0 的有效数字"
        case .notFound: "该收藏已不存在，请返回列表重试"
        }
    }
}

final class FavoriteLocationsPersistence {
    static let storageKey = "favoriteLocations.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [FavoriteLocation] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return try JSONDecoder().decode([FavoriteLocation].self, from: data)
            .filter(\.isValid)
    }

    @discardableResult
    func add(name: String, coordinateWGS84: LocationCoordinate,
             address: String? = nil, accuracy: Double? = nil) throws -> [FavoriteLocation] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw FavoriteLocationError.emptyName }
        guard coordinateWGS84.isValid else { throw FavoriteLocationError.invalidCoordinate }
        if let accuracy, !accuracy.isFinite || accuracy <= 0 {
            throw FavoriteLocationError.invalidAccuracy
        }

        var favorites = try load()
        let existingIndex = favorites.firstIndex {
            $0.coordinateWGS84.isSamePosition(as: coordinateWGS84)
        }
        let favorite = FavoriteLocation(
            id: existingIndex.map { favorites[$0].id } ?? UUID(),
            name: trimmedName,
            coordinateWGS84: coordinateWGS84,
            address: address ?? existingIndex.flatMap { favorites[$0].address },
            accuracy: accuracy ?? existingIndex.flatMap { favorites[$0].accuracy }
        )
        if let existingIndex {
            favorites[existingIndex] = favorite
        } else {
            favorites.insert(favorite, at: 0)
        }
        try save(favorites)
        return favorites
    }

    func rename(id: UUID, name: String) throws -> [FavoriteLocation] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FavoriteLocationError.emptyName }
        var favorites = try load()
        guard let index = favorites.firstIndex(where: { $0.id == id }) else {
            throw FavoriteLocationError.notFound
        }
        let original = favorites[index]
        favorites[index] = FavoriteLocation(id: original.id, name: name,
            coordinateWGS84: original.coordinateWGS84, address: original.address,
            accuracy: original.accuracy)
        try save(favorites)
        return favorites
    }

    @discardableResult
    func remove(id: UUID) throws -> [FavoriteLocation] {
        var favorites = try load()
        favorites.removeAll { $0.id == id }
        try save(favorites)
        return favorites
    }

    private func save(_ favorites: [FavoriteLocation]) throws {
        let data = try JSONEncoder().encode(favorites)
        defaults.set(data, forKey: Self.storageKey)
    }
}
