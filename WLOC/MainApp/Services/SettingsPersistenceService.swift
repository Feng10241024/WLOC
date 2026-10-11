import Foundation

struct PersistedSettings: Equatable, Sendable {
    var location: LocationConfiguration?
    var rewriteEnabled: Bool
    var configurationVersion: Int
}

final class SettingsPersistenceService: @unchecked Sendable {
    enum Key {
        static let longitude = "mockLongitude"
        static let latitude = "mockLatitude"
        static let accuracy = "mockAccuracy"
        static let accuracyDefaultMigrationVersion = "accuracyDefaultMigrationVersion"
        static let rewriteEnabled = "rewriteEnabled"
        static let configurationVersion = "configurationVersion"
    }

    private static let currentAccuracyDefaultMigrationVersion = 1
    private static let legacyDefaultAccuracy = 25.0

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    convenience init(appGroupIdentifier: String) {
        self.init(
            defaults: UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        )
    }

    func load() -> PersistedSettings {
        let location: LocationConfiguration?
        if defaults.object(forKey: Key.longitude) != nil,
           defaults.object(forKey: Key.latitude) != nil {
            let accuracy = migratedAccuracy()
            let candidate = LocationConfiguration(
                longitude: defaults.double(forKey: Key.longitude),
                latitude: defaults.double(forKey: Key.latitude),
                accuracy: accuracy
            )
            location = candidate.isValid ? candidate : nil
        } else {
            markAccuracyDefaultMigrationComplete()
            location = nil
        }

        return PersistedSettings(
            location: location,
            rewriteEnabled: defaults.bool(forKey: Key.rewriteEnabled),
            configurationVersion: max(0, defaults.integer(forKey: Key.configurationVersion))
        )
    }

    private func migratedAccuracy() -> Double {
        let hasStoredAccuracy = defaults.object(forKey: Key.accuracy) != nil
        var accuracy = hasStoredAccuracy
            ? defaults.double(forKey: Key.accuracy)
            : SharedConstants.defaultAccuracy
        let migrationVersion = defaults.integer(
            forKey: Key.accuracyDefaultMigrationVersion
        )
        if migrationVersion < Self.currentAccuracyDefaultMigrationVersion,
           accuracy == Self.legacyDefaultAccuracy {
            accuracy = SharedConstants.defaultAccuracy
            defaults.set(accuracy, forKey: Key.accuracy)
        }
        markAccuracyDefaultMigrationComplete()
        return accuracy
    }

    private func markAccuracyDefaultMigrationComplete() {
        defaults.set(
            Self.currentAccuracyDefaultMigrationVersion,
            forKey: Key.accuracyDefaultMigrationVersion
        )
    }

    @discardableResult
    func save(
        location: LocationConfiguration?,
        rewriteEnabled: Bool,
        incrementVersion: Bool
    ) -> Int {
        if let location, location.isValid {
            defaults.set(location.longitude, forKey: Key.longitude)
            defaults.set(location.latitude, forKey: Key.latitude)
            defaults.set(location.accuracy, forKey: Key.accuracy)
        } else {
            defaults.removeObject(forKey: Key.longitude)
            defaults.removeObject(forKey: Key.latitude)
            defaults.removeObject(forKey: Key.accuracy)
        }
        defaults.set(rewriteEnabled, forKey: Key.rewriteEnabled)

        let currentVersion = max(0, defaults.integer(forKey: Key.configurationVersion))
        let nextVersion = incrementVersion ? currentVersion + 1 : currentVersion
        defaults.set(nextVersion, forKey: Key.configurationVersion)
        return nextVersion
    }

    func sharedConfiguration() -> SharedLocationConfiguration? {
        let persisted = load()
        guard let location = persisted.location else {
            return nil
        }
        return SharedLocationConfiguration(
            longitude: location.longitude,
            latitude: location.latitude,
            accuracy: location.accuracy,
            rewriteEnabled: persisted.rewriteEnabled,
            configurationVersion: persisted.configurationVersion
        )
    }
}
