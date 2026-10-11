import Foundation

enum AuthorizedHostPolicy {
    nonisolated private static let prohibitedSystemSuffixes = [
        "icloud.com",
        "mzstatic.com"
    ]

    nonisolated static func validatedHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty,
              host != "*",
              !host.contains("/"),
              !host.contains(":"),
              host.range(
                of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#,
                options: .regularExpression
              ) != nil,
              !isProhibitedSystemHost(host)
        else {
            return nil
        }
        return host
    }

    nonisolated private static func isProhibitedSystemHost(_ host: String) -> Bool {
        prohibitedSystemSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }
}
