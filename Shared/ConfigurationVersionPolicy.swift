import Foundation

enum ConfigurationVersionPolicy {
    static func shouldAccept(
        currentVersion: Int,
        requestedVersion: Int,
        loadedVersion: Int
    ) -> Bool {
        loadedVersion >= currentVersion && loadedVersion >= requestedVersion
    }
}
