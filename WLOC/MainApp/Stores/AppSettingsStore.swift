import Combine
import Foundation

struct MockLocationUpdateOutcome: Equatable, Sendable {
    let saved: Bool
    let appliedToRunningTunnel: Bool
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var mockLongitude: Double?
    @Published private(set) var mockLatitude: Double?
    @Published private(set) var mockAccuracy: Double
    @Published private(set) var rewriteEnabled: Bool
    @Published var vpnStatus: VPNConnectionStatus
    @Published var locationMessage: String?
    @Published var configurationMessage: String?
    @Published var lastErrorMessage: String?
    let tunnelMode: TunnelOperatingMode

    private let persistence: SettingsPersistenceService
    private let sharedConfiguration: SharedConfigurationService

    init(
        persistence: SettingsPersistenceService,
        sharedConfiguration: SharedConfigurationService,
        tunnelMode: TunnelOperatingMode = .localForwarding
    ) {
        self.persistence = persistence
        self.sharedConfiguration = sharedConfiguration
        self.tunnelMode = tunnelMode

        let saved = persistence.load()
        mockLongitude = saved.location?.longitude
        mockLatitude = saved.location?.latitude
        mockAccuracy = saved.location?.accuracy ?? SharedConstants.defaultAccuracy
        rewriteEnabled = saved.rewriteEnabled
        vpnStatus = .notConfigured
    }

    var mockLocation: LocationConfiguration? {
        guard let mockLongitude, let mockLatitude else {
            return nil
        }
        let location = LocationConfiguration(
            longitude: mockLongitude,
            latitude: mockLatitude,
            accuracy: mockAccuracy
        )
        return location.isValid ? location : nil
    }

    @discardableResult
    func initializeTestLocationIfNeeded(
        longitude: Double,
        latitude: Double
    ) async -> Bool {
        guard mockLocation == nil else {
            return false
        }
        let outcome = await updateMockLocationWithApplicationResult(
            longitude: longitude,
            latitude: latitude,
            accuracy: SharedConstants.defaultAccuracy
        )
        guard outcome.saved,
              mockLongitude == longitude,
              mockLatitude == latitude
        else {
            return outcome.saved
        }
        reportStatus("已使用当前位置初始化测试位置")
        return true
    }

    func updateMockLocationWithApplicationResult(
        longitude: Double,
        latitude: Double,
        accuracy: Double
    ) async -> MockLocationUpdateOutcome {
        let candidate = LocationConfiguration(
            longitude: longitude,
            latitude: latitude,
            accuracy: accuracy
        )
        guard candidate.isValid else {
            locationMessage = nil
            lastErrorMessage = "坐标或精度超出合法范围"
            return MockLocationUpdateOutcome(
                saved: false,
                appliedToRunningTunnel: false
            )
        }

        mockLongitude = longitude
        mockLatitude = latitude
        mockAccuracy = accuracy
        let result = await sharedConfiguration.save(
            location: candidate,
            rewriteEnabled: rewriteEnabled
        )
        applyProviderResponse(result.response)
        let outcome = MockLocationUpdateOutcome(
            saved: true,
            appliedToRunningTunnel: Self.wasAppliedToRunningTunnel(
                version: result.version,
                response: result.response
            )
        )
        reportStatus(outcome.appliedToRunningTunnel
            ? "测试位置已更新并同步到当前网络"
            : "测试位置已更新")
        return outcome
    }

    func setRewriteEnabled(_ enabled: Bool) async {
        rewriteEnabled = enabled
        let result = await sharedConfiguration.save(
            location: mockLocation,
            rewriteEnabled: enabled
        )
        applyProviderResponse(result.response)
    }

    func reportError(_ message: String) {
        locationMessage = nil
        lastErrorMessage = message
    }

    func reportStatus(_ message: String) {
        lastErrorMessage = nil
        locationMessage = message
    }

    private func applyProviderResponse(_ response: TunnelProviderResponse?) {
        guard let response else {
            configurationMessage = nil
            return
        }
        switch response.result {
        case .configurationLoaded, .status:
            configurationMessage = "配置已生效（版本 \(response.loadedConfigurationVersion)）"
        case .rejectedStaleConfiguration:
            configurationMessage = "扩展已加载更新版本配置"
        case .invalidConfiguration, .failed:
            configurationMessage = response.message ?? "扩展未能加载配置"
        }
    }

    nonisolated private static func wasAppliedToRunningTunnel(
        version: Int,
        response: TunnelProviderResponse?
    ) -> Bool {
        guard let response,
              response.loadedConfigurationVersion >= version
        else {
            return false
        }
        switch response.result {
        case .configurationLoaded, .status, .rejectedStaleConfiguration:
            return true
        case .invalidConfiguration, .failed:
            return false
        }
    }
}
