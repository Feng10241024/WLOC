import Combine
import CoreLocation
import Foundation

@MainActor
final class InitialTestLocationService: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()
    private var requestInProgress = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocationIfNeeded() {
        guard !requestInProgress, location == nil else {
            return
        }
        requestInProgress = true
        continueRequestForCurrentAuthorization()
    }

    private func continueRequestForCurrentAuthorization() {
        guard CLLocationManager.locationServicesEnabled() else {
            finishWithError("系统定位服务未开启，请长按地图或在设置页手动设置测试位置")
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finishWithError("无法获取当前位置，请长按地图或在设置页手动设置测试位置")
        @unknown default:
            finishWithError("无法确认定位权限，请手动设置测试位置")
        }
    }

    private func finishWithError(_ message: String) {
        requestInProgress = false
        errorMessage = message
    }
}

extension InitialTestLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard requestInProgress else {
                return
            }
            continueRequestForCurrentAuthorization()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last,
              latest.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(latest.coordinate)
        else {
            return
        }
        Task { @MainActor in
            requestInProgress = false
            errorMessage = nil
            location = latest
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            if let locationError = error as? CLError,
               locationError.code == .denied {
                finishWithError(
                    "无法获取当前位置，请长按地图或在设置页手动设置测试位置"
                )
            } else {
                finishWithError("当前位置获取失败，请手动设置测试位置")
            }
        }
    }
}
