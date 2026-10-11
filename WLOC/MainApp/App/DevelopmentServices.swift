import Foundation

/// Debug-only UI tests use an isolated domain and deterministic network services.
/// Release builds always use the real device preferences, MapKit and geocoder.
@MainActor
enum DevelopmentServices {
    static var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["WLOC_UI_TEST_SESSION"] != nil
        #else
        false
        #endif
    }

    static func settingsDefaults(appGroupIdentifier: String) -> UserDefaults {
        #if DEBUG
        if isUITesting { return testingDefaults }
        #endif
        return UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static var favoritesDefaults: UserDefaults {
        #if DEBUG
        if isUITesting { return testingDefaults }
        #endif
        return .standard
    }

    static func makeSearchStore() -> PlaceSearchStore {
        #if DEBUG
        if isUITesting { return PlaceSearchStore(service: UITestPlaceSearch()) }
        #endif
        return PlaceSearchStore()
    }

    static func makeSelectionStore() -> LocationSelectionStore {
        #if DEBUG
        if isUITesting { return LocationSelectionStore(resolver: UITestAddressResolver()) }
        #endif
        return LocationSelectionStore()
    }

    #if DEBUG
    private static let testingDefaults: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        let domain = "WLOC.UITests." + (environment["WLOC_UI_TEST_SESSION"] ?? "unused")
        let defaults = UserDefaults(suiteName: domain)!
        if environment["WLOC_UI_TEST_RESET"] == "1" {
            defaults.removePersistentDomain(forName: domain)
            let selection = try! LocationSelection.manual(longitude: "114.4", latitude: "30.6", accuracy: "5")
            defaults.set(selection.coordinateWGS84.longitude, forKey: "mockLongitude")
            defaults.set(selection.coordinateWGS84.latitude, forKey: "mockLatitude")
            defaults.set(5.0, forKey: "mockAccuracy")
        }
        return defaults
    }()
    #endif
}

#if DEBUG
@MainActor
private final class UITestPlaceSearch: PlaceSearching {
    func search(query: String) async throws -> [PlaceSearchResult] {
        [PlaceSearchResult(name: "武汉站", address: "湖北省武汉市洪山区",
            mapCoordinate: LocationCoordinate(latitude: 30.606981, longitude: 114.424338))]
    }
    func cancel() {}
}

@MainActor
private struct UITestAddressResolver: LocationAddressResolving {
    func resolve(_ coordinate: LocationCoordinate) async throws -> ResolvedLocationAddress? {
        ResolvedLocationAddress(name: "地图测试地点", address: "界面测试地址")
    }
}
#endif
