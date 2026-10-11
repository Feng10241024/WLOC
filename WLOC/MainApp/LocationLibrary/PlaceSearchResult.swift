import Foundation

struct PlaceSearchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let address: String
    // MapKit search results already use the map's coordinate space. Do not
    // apply the app's WGS-84 -> GCJ-02 conversion again when centering on them.
    let mapCoordinate: LocationCoordinate

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        mapCoordinate: LocationCoordinate
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.mapCoordinate = mapCoordinate
    }
}
