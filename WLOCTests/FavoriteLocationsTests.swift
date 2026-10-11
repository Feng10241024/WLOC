import Foundation
import Testing
#if canImport(WLOCLocationLibrary)
@testable import WLOCLocationLibrary
#else
@testable import WLOC
#endif

struct FavoriteLocationsTests {
    private let coordinate = LocationCoordinate(latitude: 30.6, longitude: 114.4)

    @Test func savingPersistsNameAndExactCoordinatesAcrossInstances() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        let saved = try persistence.add(name: "  武汉火车站南广场\n", coordinateWGS84: coordinate)
        let restored = try FavoriteLocationsPersistence(defaults: suite.defaults).load()
        #expect(restored == saved)
        #expect(restored.count == 1)
        #expect(restored[0].name == "武汉火车站南广场")
        #expect(restored[0].coordinateWGS84 == coordinate)
    }

    @Test func savingSamePointUpdatesNameWithoutDuplicatingOrChangingIdentity() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        let original = try persistence.add(name: "车站", coordinateWGS84: coordinate)[0]
        let closeCoordinate = LocationCoordinate(latitude: 30.600_000_1, longitude: 114.400_000_1)
        let updated = try persistence.add(name: "南广场", coordinateWGS84: closeCoordinate)
        #expect(updated.count == 1)
        #expect(updated[0].id == original.id)
        #expect(updated[0].name == "南广场")
        #expect(updated[0].coordinateWGS84 == closeCoordinate)
    }

    @Test func distinctPointsWithSameNameRemainSeparateAndNewestComesFirst() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        let first = try persistence.add(name: "入口", coordinateWGS84: coordinate)[0]
        let secondCoordinate = LocationCoordinate(latitude: 30.61, longitude: 114.41)
        let saved = try persistence.add(name: "入口", coordinateWGS84: secondCoordinate)
        #expect(saved.count == 2)
        #expect(saved[0].coordinateWGS84 == secondCoordinate)
        #expect(saved[1] == first)
    }

    @Test func emptyNameIsRejectedWithoutChangingExistingFavorites() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        let original = try persistence.add(name: "已收藏", coordinateWGS84: coordinate)
        #expect(throws: FavoriteLocationError.emptyName) {
            try persistence.add(name: " \n\t", coordinateWGS84: coordinate)
        }
        #expect(try persistence.load() == original)
    }

    @Test(arguments: [
        LocationCoordinate(latitude: 91, longitude: 114),
        LocationCoordinate(latitude: 30, longitude: -181),
        LocationCoordinate(latitude: .nan, longitude: 114),
        LocationCoordinate(latitude: 30, longitude: .infinity)
    ])
    func invalidCoordinatesAreRejectedWithoutChangingStoredData(_ invalid: LocationCoordinate) throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        let original = try persistence.add(name: "已收藏", coordinateWGS84: coordinate)
        #expect(throws: FavoriteLocationError.invalidCoordinate) {
            try persistence.add(name: "无效", coordinateWGS84: invalid)
        }
        #expect(try persistence.load() == original)
    }

    @Test func deletingOnePointPersistsAndPreservesOtherSettings() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        suite.defaults.set(114.123, forKey: "mockLongitude")
        suite.defaults.set(true, forKey: "rewriteEnabled")
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        let deleted = try persistence.add(name: "一", coordinateWGS84: coordinate)[0]
        let remaining = try persistence.add(
            name: "二",
            coordinateWGS84: LocationCoordinate(latitude: 31, longitude: 115)
        )[0]
        _ = try persistence.remove(id: deleted.id)
        #expect(try FavoriteLocationsPersistence(defaults: suite.defaults).load() == [remaining])
        #expect(suite.defaults.double(forKey: "mockLongitude") == 114.123)
        #expect(suite.defaults.bool(forKey: "rewriteEnabled"))
        #expect(try persistence.remove(id: UUID()) == [remaining])
    }

    @Test func corruptDataIsReportedAndNotOverwrittenByAddOrDelete() {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let corruptData = Data("invalid JSON".utf8)
        suite.defaults.set(corruptData, forKey: FavoriteLocationsPersistence.storageKey)
        let persistence = FavoriteLocationsPersistence(defaults: suite.defaults)
        #expect(throws: (any Error).self) { try persistence.load() }
        #expect(throws: (any Error).self) {
            try persistence.add(name: "新收藏", coordinateWGS84: coordinate)
        }
        #expect(throws: (any Error).self) { try persistence.remove(id: UUID()) }
        #expect(suite.defaults.data(forKey: FavoriteLocationsPersistence.storageKey) == corruptData)
    }

    @Test func invalidPersistedRecordsAreHidden() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let valid = FavoriteLocation(name: "正常", coordinateWGS84: coordinate)
        let invalid = FavoriteLocation(
            name: "异常",
            coordinateWGS84: LocationCoordinate(latitude: 100, longitude: 114)
        )
        let blank = FavoriteLocation(name: " ", coordinateWGS84: coordinate)
        suite.defaults.set(
            try JSONEncoder().encode([valid, invalid, blank]),
            forKey: FavoriteLocationsPersistence.storageKey
        )
        #expect(try FavoriteLocationsPersistence(defaults: suite.defaults).load() == [valid])
    }

    @Test @MainActor func storePublishesAddedAndDeletedFavoritesAndValidationErrors() throws {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        let store = FavoriteLocationsStore(
            persistence: FavoriteLocationsPersistence(defaults: suite.defaults)
        )
        #expect(store.favorites.isEmpty)
        #expect(!store.add(name: " ", coordinateWGS84: coordinate))
        #expect(store.errorMessage != nil)
        #expect(store.add(name: "车站", coordinateWGS84: coordinate))
        #expect(store.errorMessage == nil)
        let favorite = try #require(store.favorites.first)
        store.remove(favorite)
        #expect(store.favorites.isEmpty)
        #expect(store.errorMessage == nil)
        #expect(try FavoriteLocationsPersistence(defaults: suite.defaults).load().isEmpty)
    }

    @Test @MainActor func storeReportsReadFailureWithoutPretendingStorageIsEmpty() {
        let suite = DefaultsTestSuite()
        defer { suite.cleanUp() }
        suite.defaults.set(Data("broken".utf8), forKey: FavoriteLocationsPersistence.storageKey)
        let store = FavoriteLocationsStore(
            persistence: FavoriteLocationsPersistence(defaults: suite.defaults)
        )
        #expect(store.errorMessage?.contains("读取收藏失败") == true)
        #expect(!store.add(name: "车站", coordinateWGS84: coordinate))
        #expect(store.errorMessage != nil)
    }
}

private struct DefaultsTestSuite {
    let name = "WLOC.Favorites.Tests.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func cleanUp() { defaults.removePersistentDomain(forName: name) }
}
