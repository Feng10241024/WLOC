import MapKit

@MainActor
protocol PlaceSearching: AnyObject {
    func search(query: String) async throws -> [PlaceSearchResult]
    func cancel()
}

@MainActor
final class MapKitPlaceSearchService: PlaceSearching {
    private var activeSearch: MKLocalSearch?

    func search(query: String) async throws -> [PlaceSearchResult] {
        cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        // A named city in the query must remain searchable even when the
        // current test location is far away, so no nearby-only region is set.
        let search = MKLocalSearch(request: request)
        activeSearch = search
        defer {
            if activeSearch === search {
                activeSearch = nil
            }
        }
        let response = try await search.start()
        try Task.checkCancellation()
        return response.mapItems.compactMap { item in
            let coordinate: CLLocationCoordinate2D
            let address: String
            if #available(iOS 26.0, macOS 26.0, *) {
                coordinate = item.location.coordinate
                address = item.address?.fullAddress ?? ""
            } else {
                coordinate = item.placemark.coordinate
                address = item.placemark.title ?? ""
            }
            let location = LocationCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            guard location.isValid else { return nil }
            return PlaceSearchResult(
                name: item.name ?? query,
                address: address,
                mapCoordinate: location
            )
        }
    }

    func cancel() {
        activeSearch?.cancel()
        activeSearch = nil
    }
}
