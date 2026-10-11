import Foundation

struct TunnelRuntimeConfiguration: Sendable {
    let mode: TunnelOperatingMode
    let location: SharedLocationConfiguration?
    let allowedHosts: Set<String>
    let authorizedProxyURL: URL?
}

enum TunnelConfigurationError: LocalizedError {
    case appGroupUnavailable
    case missingLocation
    case invalidLocation
    case invalidAllowedHosts
    case invalidProxyURL

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "无法访问 App Group 共享配置"
        case .missingLocation:
            "尚未设置测试坐标"
        case .invalidLocation:
            "共享测试坐标无效"
        case .invalidAllowedHosts:
            "测试域名白名单为空或包含不安全值"
        case .invalidProxyURL:
            "授权测试代理地址无效"
        }
    }
}

struct TunnelConfigurationLoader {
    func load(providerConfiguration: [String: Any]?) throws -> TunnelRuntimeConfiguration {
        let mode = (providerConfiguration?["tunnelMode"] as? String)
            .flatMap(TunnelOperatingMode.init(rawValue:))
            ?? .diagnosticNoTraffic
        let rawHosts = providerConfiguration?["allowedHosts"] as? [String]
            ?? Array(SharedConstants.defaultAllowedHosts)
        let allowedHosts = Set(rawHosts.compactMap(AuthorizedHostPolicy.validatedHost))
        guard !allowedHosts.isEmpty, allowedHosts.count == rawHosts.count else {
            throw TunnelConfigurationError.invalidAllowedHosts
        }

        if mode == .diagnosticNoTraffic {
            return TunnelRuntimeConfiguration(
                mode: mode,
                location: nil,
                allowedHosts: allowedHosts,
                authorizedProxyURL: nil
            )
        }

        let appGroup = providerConfiguration?["appGroupIdentifier"] as? String
            ?? SharedConstants.appGroupIdentifier
        let defaults = UserDefaults(suiteName: appGroup)
        let location = try loadLocation(
            defaults: defaults,
            providerConfiguration: providerConfiguration
        )

        if mode == .localForwarding {
            return TunnelRuntimeConfiguration(
                mode: mode,
                location: location,
                allowedHosts: allowedHosts,
                authorizedProxyURL: nil
            )
        }

        guard let rawURL = providerConfiguration?["authorizedProxyURL"] as? String,
              let proxyURL = URL(string: rawURL),
              proxyURL.scheme?.lowercased() == "https",
              proxyURL.host != nil
        else {
            throw TunnelConfigurationError.invalidProxyURL
        }

        return TunnelRuntimeConfiguration(
            mode: mode,
            location: location,
            allowedHosts: allowedHosts,
            authorizedProxyURL: proxyURL
        )
    }

    /// The App Group remains the live source of truth. The embedded snapshot is
    /// refreshed every time the App starts the tunnel and only exists to recover
    /// from TrollStore reinstallations where iOS keeps an old VPN preference but
    /// gives the newly installed App/Extension a fresh shared container.
    private func loadLocation(
        defaults: UserDefaults?,
        providerConfiguration: [String: Any]?
    ) throws -> SharedLocationConfiguration {
        if let defaults,
           defaults.object(forKey: "mockLongitude") != nil,
           defaults.object(forKey: "mockLatitude") != nil {
            let shared = SharedLocationConfiguration(
                longitude: defaults.double(forKey: "mockLongitude"),
                latitude: defaults.double(forKey: "mockLatitude"),
                accuracy: defaults.object(forKey: "mockAccuracy") == nil
                    ? SharedConstants.defaultAccuracy
                    : defaults.double(forKey: "mockAccuracy"),
                rewriteEnabled: defaults.bool(forKey: "rewriteEnabled"),
                configurationVersion: max(
                    0,
                    defaults.integer(forKey: "configurationVersion")
                )
            )
            guard shared.isValid else {
                throw TunnelConfigurationError.invalidLocation
            }
            return shared
        }

        if let embedded = embeddedLocation(
            providerConfiguration: providerConfiguration
        ) {
            guard embedded.isValid else {
                throw TunnelConfigurationError.invalidLocation
            }
            return embedded
        }

        guard defaults != nil else {
            throw TunnelConfigurationError.appGroupUnavailable
        }
        throw TunnelConfigurationError.missingLocation
    }

    private func embeddedLocation(
        providerConfiguration: [String: Any]?
    ) -> SharedLocationConfiguration? {
        guard let longitude = number(
                providerConfiguration?["embeddedMockLongitude"]
              ),
              let latitude = number(
                providerConfiguration?["embeddedMockLatitude"]
              )
        else {
            return nil
        }
        return SharedLocationConfiguration(
            longitude: longitude.doubleValue,
            latitude: latitude.doubleValue,
            accuracy: number(
                providerConfiguration?["embeddedMockAccuracy"]
            )?.doubleValue ?? SharedConstants.defaultAccuracy,
            rewriteEnabled: number(
                providerConfiguration?["embeddedRewriteEnabled"]
            )?.boolValue ?? false,
            configurationVersion: max(
                0,
                number(
                    providerConfiguration?["embeddedConfigurationVersion"]
                )?.intValue ?? 0
            )
        )
    }

    private func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}
