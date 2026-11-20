import Foundation

/// Settings files for setting up several Macs the same way: export this Mac's settings, import them on another.
/// Never contains keys (those live encrypted in Wisp's own storage). An exported file can also be deployed as the
/// managed file (`/Library/Application Support/Wisp/managed-config.json`) to set and lock them for everyone.
public enum ConfigTransfer {
    public enum ImportError: Error, Equatable { case notASettingsFile }

    /// Keys that belong to this Mac only (setup progress), never exported or imported.
    static let localKeys = ["onboardingCompleted", "chordChosenByUser"]

    public static func exportData(_ config: AppConfig) throws -> Data {
        var object = try ConfigStore.toObject(config)
        for key in localKeys { object.removeValue(forKey: key) }
        object["wispSettingsFile"] = 1
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The settings in `data` laid over `current` (a file may hold only some settings); this Mac's setup progress
    /// is kept.
    public static func importing(_ data: Data, over current: AppConfig) throws -> AppConfig {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["wispSettingsFile"] != nil || object["vision"] != nil || object["speech"] != nil else {
            throw ImportError.notASettingsFile
        }
        object.removeValue(forKey: "wispSettingsFile")
        for key in localKeys { object.removeValue(forKey: key) }
        let merged = ConfigStore.merge(try ConfigStore.toObject(current), object)
        guard let config = try? ConfigStore.fromObject(merged) else { throw ImportError.notASettingsFile }
        return config
    }
}
