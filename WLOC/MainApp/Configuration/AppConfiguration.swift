import Foundation

struct AppConfiguration: Sendable {
    let certificateDownloadURL: URL?
    let certificateValidationURL: URL?
    let authorizedProxyURL: URL?
    let appGroupIdentifier: String
    let tunnelProviderBundleIdentifier: String
    let allowedHosts: Set<String>
    let tunnelMode: TunnelOperatingMode

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let fileConfiguration = loadConfigurationDictionary(bundle: bundle)
        func value<T>(_ key: String) -> T? {
            (fileConfiguration[key] as? T)
                ?? (bundle.object(forInfoDictionaryKey: key) as? T)
        }

        let hosts: Set<String> = (value("AuthorizedTestHosts") as [String]?)
            .map(Set.init)
            ?? SharedConstants.defaultAllowedHosts
        let safeHosts = Set(hosts.compactMap(AuthorizedHostPolicy.validatedHost))

        return AppConfiguration(
            certificateDownloadURL: url(value("CertificateDownloadURL")),
            certificateValidationURL: url(value("CertificateValidationURL")),
            authorizedProxyURL: url(value("AuthorizedProxyURL")),
            appGroupIdentifier: (value("AppGroupIdentifier") as String?)
                ?? SharedConstants.appGroupIdentifier,
            tunnelProviderBundleIdentifier: (value("TunnelProviderBundleIdentifier") as String?)
                ?? SharedConstants.tunnelProviderBundleIdentifier,
            allowedHosts: safeHosts.isEmpty ? SharedConstants.defaultAllowedHosts : safeHosts,
            tunnelMode: (value("TunnelMode") as String?)
                .flatMap(TunnelOperatingMode.init(rawValue:))
                ?? .localForwarding
        )
    }

    nonisolated private static func url(_ rawValue: String?) -> URL? {
        guard let value = nonPlaceholderString(rawValue),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        return url
    }

    nonisolated private static func loadConfigurationDictionary(
        bundle: Bundle
    ) -> [String: Any] {
        guard let url = bundle.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ),
              let dictionary = object as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    nonisolated private static func nonPlaceholderString(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              !value.hasPrefix("$("),
              value != "REPLACE_ME"
        else {
            return nil
        }
        return value
    }
}
