import CoreLocation
import Foundation
import Testing
#if canImport(WLOCLocationLibrary)
@testable import WLOCLocationLibrary
#else
@testable import WLOC
#endif

@MainActor
struct LocationSelectionTests {
    @Test func manualCoordinatesRoundTripWithOriginalDisplayAndKeepAccuracy() throws {
        let selection = try LocationSelection.manual(longitude: " 114.424338 ",
            latitude: "30.606981", accuracy: "12,5", name: "  武汉站  ")
        #expect(abs(selection.displayCoordinate.longitude - 114.424338) < 1e-8)
        #expect(abs(selection.displayCoordinate.latitude - 30.606981) < 1e-8)
        #expect(selection.accuracy == 12.5)
        #expect(selection.name == "武汉站")
        #expect(selection.coordinateWGS84.longitude != selection.displayCoordinate.longitude)
    }

    @Test func searchAndMapSelectionAtSamePointHaveSameStoredCoordinate() throws {
        let result = PlaceSearchResult(name: "武汉站", address: "武汉市洪山区",
            mapCoordinate: LocationCoordinate(latitude: 30.606981, longitude: 114.424338))
        let search = LocationSelection.searchResult(result, accuracy: 7)
        let map = try LocationSelection.manual(longitude: "114.424338", latitude: "30.606981", accuracy: "7")
        #expect(search.coordinateWGS84 == map.coordinateWGS84)
        #expect(search.address == result.address)
        #expect(abs(search.displayCoordinate.longitude - result.mapCoordinate.longitude) < 1e-8)
    }

    @Test func overseasCoordinatesDoNotReceiveChinaOffset() throws {
        let selection = try LocationSelection.manual(longitude: "-122.4194", latitude: "37.7749", accuracy: "5")
        #expect(selection.coordinateWGS84 == selection.displayCoordinate)
    }

    @Test(arguments: [("181", "30", "5"), ("114", "91", "5"),
                      ("nan", "30", "5"), ("114", "30", "0"),
                      ("114", "30", "-1"), ("114", "30", "inf"),
                      ("", "30", "5"), ("abc", "30", "5")])
    func invalidManualInputCannotProduceASelection(_ input: (String, String, String)) {
        #expect(throws: (any Error).self) {
            try LocationSelection.manual(longitude: input.0, latitude: input.1, accuracy: input.2)
        }
    }

    @Test func oldFavoritesWithoutAddressOrAccuracyRemainReadable() throws {
        let defaults = isolatedDefaults()
        defer { defaults.cleanUp() }
        let id = UUID()
        let json = """
        [{"id":"\(id)","name":"旧收藏","coordinateWGS84":{"latitude":30.6,"longitude":114.4}}]
        """
        defaults.value.set(Data(json.utf8), forKey: FavoriteLocationsPersistence.storageKey)
        let favorite = try #require(FavoriteLocationsPersistence(defaults: defaults.value).load().first)
        #expect(favorite.id == id)
        #expect(favorite.address == nil)
        #expect(favorite.accuracy == nil)
        #expect(LocationSelection.favorite(favorite, fallbackAccuracy: 9).accuracy == 9)
    }

    @Test func savingAllThreeSourcesPreservesNameAddressAccuracyAcrossRelaunch() throws {
        let defaults = isolatedDefaults()
        defer { defaults.cleanUp() }
        let store = FavoriteLocationsStore(persistence: FavoriteLocationsPersistence(defaults: defaults.value))
        let map = LocationSelection(name: "地图地点", address: "地图地址",
            coordinateWGS84: LocationCoordinate(latitude: 30.6, longitude: 114.4), accuracy: 3)
        let search = LocationSelection.searchResult(PlaceSearchResult(name: "武汉站", address: "车站地址",
            mapCoordinate: LocationCoordinate(latitude: 30.606981, longitude: 114.424338)), accuracy: 5)
        let manual = try LocationSelection.manual(longitude: "115", latitude: "31", accuracy: "12", name: "坐标地点")
        for selection in [map, search, manual] { #expect(store.add(selection)) }
        let restored = FavoriteLocationsStore(persistence: FavoriteLocationsPersistence(defaults: defaults.value))
        #expect(restored.favorites.count == 3)
        #expect(restored.favorites.last?.address == "地图地址")
        #expect(restored.favorites.first?.accuracy == 12)
        #expect(LocationSelection.favorite(restored.favorites[1], fallbackAccuracy: 99).accuracy == 5)
    }

    @Test func renameOnlyChangesNameAndKeepsIdentityPositionAddressAndAccuracy() throws {
        let defaults = isolatedDefaults()
        defer { defaults.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: defaults.value)
        let original = try persistence.add(name: "旧名称",
            coordinateWGS84: LocationCoordinate(latitude: 30.6, longitude: 114.4),
            address: "地址", accuracy: 12)[0]
        let updated = try persistence.rename(id: original.id, name: "  新名称 ")[0]
        #expect(updated.name == "新名称")
        #expect(updated.id == original.id)
        #expect(updated.coordinateWGS84 == original.coordinateWGS84)
        #expect(updated.address == original.address)
        #expect(updated.accuracy == original.accuracy)
        #expect(throws: FavoriteLocationError.emptyName) { try persistence.rename(id: original.id, name: " ") }
        #expect(try persistence.load() == [updated])
        #expect(throws: FavoriteLocationError.notFound) { try persistence.rename(id: UUID(), name: "不存在") }
        #expect(try persistence.load() == [updated])
    }

    @Test func invalidAccuracyCannotOverwriteExistingFavorite() throws {
        let defaults = isolatedDefaults()
        defer { defaults.cleanUp() }
        let persistence = FavoriteLocationsPersistence(defaults: defaults.value)
        let original = try persistence.add(name: "车站", coordinateWGS84: .init(latitude: 30, longitude: 114), accuracy: 8)
        #expect(throws: FavoriteLocationError.invalidAccuracy) {
            try persistence.add(name: "车站", coordinateWGS84: .init(latitude: 30, longitude: 114), accuracy: 0)
        }
        #expect(try persistence.load() == original)
    }

    @Test func lateAddressResponseCannotOverwriteNewSelection() async throws {
        let resolver = ControlledAddressResolver()
        let store = LocationSelectionStore(resolver: resolver)
        let first = LocationSelection(name: "一", coordinateWGS84: .init(latitude: 30, longitude: 114), accuracy: 5)
        let second = LocationSelection(name: "二", coordinateWGS84: .init(latitude: 31, longitude: 115), accuracy: 5)
        store.select(first, resolveAddress: true)
        await waitForRequests(1, resolver: resolver)
        store.select(second, resolveAddress: true)
        await waitForRequests(2, resolver: resolver)
        #expect(resolver.cancelCount == 2)
        resolver.requests[1].resume(returning: .init(name: "第二地址", address: "地址二"))
        for _ in 0..<20 { await Task.yield() }
        resolver.requests[0].resume(returning: .init(name: "过期地址", address: "地址一"))
        for _ in 0..<20 { await Task.yield() }
        #expect(store.selection?.id == second.id)
        #expect(store.selection?.name == "第二地址")
        #expect(!store.isResolvingAddress)
    }

    @Test func addressFailureKeepsSelectionAvailableForOneTapSave() async throws {
        let resolver = ControlledAddressResolver()
        let selectionStore = LocationSelectionStore(resolver: resolver)
        let selection = try LocationSelection.manual(longitude: "114", latitude: "30", accuracy: "5")
        selectionStore.select(selection, resolveAddress: true)
        await waitForRequests(1, resolver: resolver)
        resolver.requests[0].resume(throwing: URLError(.notConnectedToInternet))
        for _ in 0..<20 { await Task.yield() }
        #expect(selectionStore.selection == selection)
        #expect(!selectionStore.isResolvingAddress)
        let defaults = isolatedDefaults()
        defer { defaults.cleanUp() }
        let favorites = FavoriteLocationsStore(persistence: FavoriteLocationsPersistence(defaults: defaults.value))
        #expect(favorites.favorites.isEmpty)
        #expect(favorites.add(try #require(selectionStore.selection)))
        #expect(favorites.favorites.count == 1)
    }

    @Test func replacingSelectionBeforeLookupStartsSkipsCancelledRequest() async throws {
        let resolver = ControlledAddressResolver()
        let store = LocationSelectionStore(resolver: resolver)
        let first = LocationSelection(name: "一", coordinateWGS84: .init(latitude: 30, longitude: 114), accuracy: 5)
        let second = LocationSelection(name: "二", coordinateWGS84: .init(latitude: 31, longitude: 115), accuracy: 5)
        store.select(first, resolveAddress: true)
        store.select(second, resolveAddress: true)
        await waitForRequests(1, resolver: resolver)
        #expect(resolver.cancelCount == 2)
        resolver.requests[0].resume(returning: .init(name: "第二地址", address: "地址二"))
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.requests.count == 1)
        #expect(store.selection?.id == second.id)
        #expect(store.selection?.name == "第二地址")
    }

    private func waitForRequests(_ count: Int, resolver: ControlledAddressResolver) async {
        for _ in 0..<1000 {
            if resolver.requests.count == count { return }
            await Task.yield()
        }
        Issue.record("Address request did not start")
    }
}

@MainActor
private final class ControlledAddressResolver: LocationAddressResolving {
    var requests: [CheckedContinuation<ResolvedLocationAddress?, Error>] = []
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
    func resolve(_ coordinate: LocationCoordinate) async throws -> ResolvedLocationAddress? {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
}

private struct SelectionTestDefaults {
    let domain = "WLOC.Selection.Tests.\(UUID())"
    var value: UserDefaults { UserDefaults(suiteName: domain)! }
    func cleanUp() { value.removePersistentDomain(forName: domain) }
}

private func isolatedDefaults() -> SelectionTestDefaults { SelectionTestDefaults() }
