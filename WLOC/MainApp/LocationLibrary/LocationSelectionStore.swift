import Combine
import CoreLocation
import Foundation

struct ResolvedLocationAddress: Equatable, Sendable {
    let name: String
    let address: String
}

@MainActor
protocol LocationAddressResolving {
    func resolve(_ coordinate: LocationCoordinate) async throws -> ResolvedLocationAddress?
    func cancel()
}

extension LocationAddressResolving { func cancel() {} }

@MainActor
final class GeocoderAddressResolver: LocationAddressResolving {
    private let geocoder = CLGeocoder()
    func cancel() { geocoder.cancelGeocode() }
    func resolve(_ coordinate: LocationCoordinate) async throws -> ResolvedLocationAddress? {
        let placemarks = try await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            preferredLocale: Locale(identifier: "zh_Hans_CN"))
        guard let placemark = placemarks.first else { return nil }
        var pieces: [String] = []
        for part in [placemark.administrativeArea, placemark.locality,
                     placemark.subLocality, placemark.thoroughfare, placemark.subThoroughfare] {
            if let part, !part.isEmpty, pieces.last != part { pieces.append(part) }
        }
        let address = pieces.joined()
        let name = placemark.name ?? address
        guard !name.isEmpty else { return nil }
        return ResolvedLocationAddress(name: name, address: address)
    }
}

@MainActor
final class LocationSelectionStore: ObservableObject {
    @Published private(set) var selection: LocationSelection?
    @Published private(set) var isResolvingAddress = false
    private let resolver: any LocationAddressResolving
    private var addressTask: Task<Void, Never>?

    init(resolver: any LocationAddressResolving) { self.resolver = resolver }
    convenience init() { self.init(resolver: GeocoderAddressResolver()) }

    func select(_ selection: LocationSelection, resolveAddress: Bool = false) {
        addressTask?.cancel()
        resolver.cancel()
        self.selection = selection
        isResolvingAddress = resolveAddress
        guard resolveAddress else { return }
        addressTask = Task {
            defer {
                if self.selection?.id == selection.id { isResolvingAddress = false }
            }
            guard !Task.isCancelled else { return }
            guard let resolved = try? await resolver.resolve(selection.coordinateWGS84),
                  !Task.isCancelled, self.selection?.id == selection.id else { return }
            self.selection?.name = resolved.name
            self.selection?.address = resolved.address
        }
    }
}
