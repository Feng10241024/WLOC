import Combine
import Foundation

@MainActor
final class FavoriteLocationsStore: ObservableObject {
    @Published private(set) var favorites: [FavoriteLocation] = []
    @Published private(set) var errorMessage: String?
    private let persistence: FavoriteLocationsPersistence

    init(persistence: FavoriteLocationsPersistence) {
        self.persistence = persistence
        do {
            favorites = try persistence.load()
        } catch {
            errorMessage = "读取收藏失败：\(error.localizedDescription)"
        }
    }

    convenience init() {
        self.init(persistence: FavoriteLocationsPersistence())
    }

    @discardableResult
    func add(name: String, coordinateWGS84: LocationCoordinate,
             address: String? = nil, accuracy: Double? = nil) -> Bool {
        do {
            favorites = try persistence.add(name: name, coordinateWGS84: coordinateWGS84,
                address: address, accuracy: accuracy)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func add(_ selection: LocationSelection) -> Bool {
        add(name: selection.name, coordinateWGS84: selection.coordinateWGS84,
            address: selection.address, accuracy: selection.accuracy)
    }

    func contains(_ coordinate: LocationCoordinate) -> Bool {
        favorites.contains { $0.coordinateWGS84.isSamePosition(as: coordinate) }
    }

    @discardableResult
    func rename(_ favorite: FavoriteLocation, name: String) -> Bool {
        do {
            favorites = try persistence.rename(id: favorite.id, name: name)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ favorite: FavoriteLocation) {
        do {
            favorites = try persistence.remove(id: favorite.id)
            errorMessage = nil
        } catch {
            errorMessage = "删除收藏失败：\(error.localizedDescription)"
        }
    }
}
