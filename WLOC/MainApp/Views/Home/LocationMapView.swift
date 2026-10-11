// Modified from xiaobovlog/WLOC for place search, favorites, and public release. See NOTICE.
import CoreLocation
import MapKit
import SwiftUI

struct MapZoomCommand: Equatable {
    enum Direction {
        case zoomIn
        case zoomOut
    }

    enum Mode {
        case singleTap
        case continuous
    }

    let id = UUID()
    let direction: Direction
    let mode: Mode
}

struct MapCenterCommand {
    let id = UUID()
    let mapCoordinate: CLLocationCoordinate2D
    let visibleDistance: CLLocationDistance?

    init(coordinateWGS84: CLLocationCoordinate2D, visibleDistance: CLLocationDistance? = nil) {
        mapCoordinate = ChinaMapCoordinateConverter.gcj02(fromWGS84: coordinateWGS84)
        self.visibleDistance = visibleDistance
    }

    init(mapCoordinate: CLLocationCoordinate2D, visibleDistance: CLLocationDistance = 2_000) {
        self.mapCoordinate = mapCoordinate
        self.visibleDistance = visibleDistance
    }
}

struct LocationMapView: UIViewRepresentable {
    let mockLocationWGS84: CLLocationCoordinate2D?
    let centerCommand: MapCenterCommand?
    let zoomCommand: MapZoomCommand?
    let searchResult: PlaceSearchResult?
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onMapError: (String) -> Void
    let onMapLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.accessibilityIdentifier = "location.map"

        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        gesture.minimumPressDuration = 0.65
        gesture.numberOfTouchesRequired = 1
        gesture.cancelsTouchesInView = false
        mapView.addGestureRecognizer(gesture)
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        let mockMapCoordinate = mockLocationWGS84.map(
            ChinaMapCoordinateConverter.gcj02
        )
        context.coordinator.updateAnnotation(mock: mockMapCoordinate)
        context.coordinator.updateSearchAnnotation(searchResult)
        context.coordinator.applyInitialRegionIfNeeded(
            centeredOn: mockMapCoordinate,
            to: mapView
        )
        context.coordinator.applyCenterCommand(centerCommand, to: mapView)
        context.coordinator.applyZoomCommand(zoomCommand, to: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LocationMapView
        weak var mapView: MKMapView?
        private var didApplyInitialRegion = false
        private var handledCenterCommandID: UUID?
        private var handledZoomCommandID: UUID?
        private var mockAnnotation: LocationAnnotation?
        private var searchAnnotation: LocationAnnotation?

        init(parent: LocationMapView) {
            self.parent = parent
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView else {
                return
            }
            let point = gesture.location(in: mapView)
            let mapCoordinate = mapView.convert(
                point,
                toCoordinateFrom: mapView
            )
            parent.onLongPress(
                ChinaMapCoordinateConverter.wgs84(fromGCJ02: mapCoordinate)
            )
        }

        func updateAnnotation(mock: CLLocationCoordinate2D?) {
            guard let mapView else {
                return
            }
            updateAnnotation(
                &mockAnnotation,
                coordinate: mock,
                title: "测试位置",
                mapView: mapView
            )
        }

        func updateSearchAnnotation(_ result: PlaceSearchResult?) {
            guard let mapView else { return }
            updateAnnotation(
                &searchAnnotation,
                coordinate: result?.mapCoordinate.coreLocationCoordinate,
                title: result.map { "搜索：\($0.name)" } ?? "搜索地点",
                mapView: mapView
            )
        }

        func applyInitialRegionIfNeeded(
            centeredOn coordinate: CLLocationCoordinate2D?,
            to mapView: MKMapView
        ) {
            guard !didApplyInitialRegion, let coordinate else {
                return
            }
            didApplyInitialRegion = true
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 2_000,
                longitudinalMeters: 2_000
            )
            mapView.setRegion(region, animated: false)
        }

        func applyCenterCommand(
            _ command: MapCenterCommand?,
            to mapView: MKMapView
        ) {
            guard let command, command.id != handledCenterCommandID else {
                return
            }
            handledCenterCommandID = command.id
            if let distance = command.visibleDistance {
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: command.mapCoordinate,
                        latitudinalMeters: distance,
                        longitudinalMeters: distance
                    ),
                    animated: true
                )
            } else {
                mapView.setCenter(command.mapCoordinate, animated: true)
            }
        }

        func applyZoomCommand(_ command: MapZoomCommand?, to mapView: MKMapView) {
            guard let command, command.id != handledZoomCommandID else {
                return
            }
            handledZoomCommandID = command.id

            let scale: Double
            switch (command.direction, command.mode) {
            case (.zoomIn, .singleTap):
                scale = 0.5
            case (.zoomOut, .singleTap):
                scale = 2.0
            case (.zoomIn, .continuous):
                scale = 0.72
            case (.zoomOut, .continuous):
                scale = 1.4
            }
            var region = mapView.region
            region.span.latitudeDelta = min(
                max(region.span.latitudeDelta * scale, 0.000_1),
                120
            )
            region.span.longitudeDelta = min(
                max(region.span.longitudeDelta * scale, 0.000_1),
                120
            )
            mapView.setRegion(
                region,
                animated: command.mode == .singleTap
            )
        }

        private func updateAnnotation(
            _ annotation: inout LocationAnnotation?,
            coordinate: CLLocationCoordinate2D?,
            title: String,
            mapView: MKMapView
        ) {
            guard let coordinate else {
                if let annotation {
                    mapView.removeAnnotation(annotation)
                }
                annotation = nil
                return
            }
            if let annotation {
                annotation.title = title
                guard abs(annotation.coordinate.latitude - coordinate.latitude)
                        > 0.000_001
                        || abs(annotation.coordinate.longitude - coordinate.longitude)
                        > 0.000_001
                else {
                    return
                }
                annotation.coordinate = coordinate
                return
            }
            let newAnnotation = LocationAnnotation(
                coordinate: coordinate,
                title: title
            )
            annotation = newAnnotation
            mapView.addAnnotation(newAnnotation)
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: MKAnnotation
        ) -> MKAnnotationView? {
            guard let annotation = annotation as? LocationAnnotation else {
                return nil
            }
            let identifier = "LocationMarker"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true
            view.markerTintColor = annotation === searchAnnotation ? .systemBlue : .systemRed
            return view
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            parent.onMapError(error.localizedDescription)
        }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            parent.onMapLoaded()
        }
    }
}

private final class LocationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?

    init(coordinate: CLLocationCoordinate2D, title: String) {
        self.coordinate = coordinate
        self.title = title
    }
}
