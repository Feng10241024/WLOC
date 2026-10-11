import Foundation

protocol TunnelConfigurationNotifying: AnyObject {
    func notifyConfigurationChanged(version: Int) async -> TunnelProviderResponse?
}

final class SharedConfigurationService: @unchecked Sendable {
    private let persistence: SettingsPersistenceService
    weak var notifier: TunnelConfigurationNotifying?

    init(persistence: SettingsPersistenceService) {
        self.persistence = persistence
    }

    @discardableResult
    func save(
        location: LocationConfiguration?,
        rewriteEnabled: Bool
    ) async -> (version: Int, response: TunnelProviderResponse?) {
        let version = persistence.save(
            location: location,
            rewriteEnabled: rewriteEnabled,
            incrementVersion: true
        )
        let response = await notifier?.notifyConfigurationChanged(version: version)
        return (version, response)
    }
}
