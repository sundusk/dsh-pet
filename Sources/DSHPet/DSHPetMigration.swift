import Foundation

/// Copies the old MoodBall defaults into the DSH Pet namespace without deleting
/// the source values, so an older app can still be launched during an upgrade.
enum DSHPetMigration {
    private static let legacyBundleIdentifier = "com.sundusk.moodball"

    static func migrateUserDefaults() {
        guard let legacy = UserDefaults(suiteName: legacyBundleIdentifier) else { return }
        migrate(from: legacy, to: .standard)
    }

    static func migrate(in defaults: UserDefaults) {
        migrate(from: defaults, to: defaults)
    }

    static func migrate(from source: UserDefaults, to destination: UserDefaults) {
        for (key, value) in source.dictionaryRepresentation() {
            let destinationKey: String
            if key.hasPrefix("moodball.") {
                destinationKey = key.replacingOccurrences(of: "moodball.", with: "dsh-pet.")
            } else if key.hasPrefix("settings.") || key == "ballPositionX" || key == "ballPositionY" {
                destinationKey = key
            } else {
                continue
            }
            guard destination.object(forKey: destinationKey) == nil else { continue }
            destination.set(value, forKey: destinationKey)
        }
    }
}
