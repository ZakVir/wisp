import Foundation

/// Layered configuration: built-in defaults, then the user's settings, then an optional managed file
/// (for the company edition, deployed by an administrator). Any key present in the managed layer is
/// locked: the user layer cannot override it and settings UI should show it as managed.
///
/// Layers are JSON objects merged key by key (deeply), so a managed file can set just
/// `{"vision": {"modelID": "..."}}` without restating everything else.
public final class ConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private let userFileURL: URL
    private let managedFileURL: URL?
    private var userLayer: [String: Any]
    private var managedLayer: [String: Any]
    private var cached: AppConfig
    /// Problems found while loading (e.g. a corrupt user file that was reset). Content-free.
    public private(set) var loadWarnings: [String] = []

    /// - Parameters:
    ///   - userFileURL: JSON file holding only the keys the user changed.
    ///   - managedFileURL: optional admin-managed JSON file; its keys win and are locked.
    public init(userFileURL: URL, managedFileURL: URL?) {
        self.userFileURL = userFileURL
        self.managedFileURL = managedFileURL
        self.userLayer = [:]
        self.managedLayer = [:]
        self.cached = AppConfig()
        reload()
    }

    /// Standard locations: `~/Library/Application Support/Wisp/settings.json` and
    /// `/Library/Application Support/Wisp/managed-config.json` (override with `WISP_MANAGED_CONFIG`).
    public static func standard(appSupportDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ConfigStore {
        let user = appSupportDirectory.appendingPathComponent("settings.json")
        var managedPath = "/Library/Application Support/Wisp/managed-config.json"
        #if DEBUG
        // Only debug builds may point elsewhere; release builds must not let a launch flag drop admin locks.
        if let override = environment["WISP_MANAGED_CONFIG"] { managedPath = override }
        #endif
        return ConfigStore(userFileURL: user, managedFileURL: URL(fileURLWithPath: managedPath))
    }

    public var config: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Re-reads both files from disk.
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        loadWarnings = []
        userLayer = Self.readObject(at: userFileURL, warnings: &loadWarnings, label: "settings")
        if let managedFileURL, FileManager.default.fileExists(atPath: managedFileURL.path) {
            managedLayer = Self.readObject(at: managedFileURL, warnings: &loadWarnings, label: "managed config", mustBeReadable: true)
        } else {
            managedLayer = [:]
        }
        // Drop only the individual values that don't fit (wrong type), keeping a backup of the original.
        let sanitized = Self.sanitize(user: userLayer, managed: managedLayer)
        if sanitized.removed > 0 {
            loadWarnings.append("\(sanitized.removed) invalid setting(s) were reset to defaults")
            try? FileManager.default.removeItem(at: userFileURL.appendingPathExtension("bak"))
            try? FileManager.default.copyItem(at: userFileURL, to: userFileURL.appendingPathExtension("bak"))
            userLayer = sanitized.layer
            try? Self.writeObject(userLayer, to: userFileURL)
        }
        cached = Self.resolve(user: userLayer, managed: managedLayer, warnings: &loadWarnings)
    }

    /// Dotted key paths fixed by the managed layer, e.g. `"vision.modelID"`.
    public var lockedKeyPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Self.leafPaths(managedLayer)
    }

    public func isLocked(_ keyPath: String) -> Bool {
        let locked = lockedKeyPaths
        // A key is locked if it or any ancestor/descendant object is managed.
        return locked.contains { $0 == keyPath || $0.hasPrefix(keyPath + ".") || keyPath.hasPrefix($0 + ".") }
    }

    /// Applies a change to the user layer. Values for locked keys are ignored (the managed value stays).
    /// Returns the effective config after the change.
    @discardableResult
    public func update(_ change: (inout AppConfig) -> Void) throws -> AppConfig {
        lock.lock(); defer { lock.unlock() }
        var next = cached
        change(&next)
        let before = try Self.toObject(cached)
        let after = try Self.toObject(next)
        // Record only keys whose effective value changed, so defaults can evolve between versions.
        var diff = Self.diff(from: before, to: after)
        let locked = Self.leafPaths(managedLayer)
        diff = Self.removing(paths: locked, from: diff)
        let nextLayer = Self.merge(userLayer, diff)
        // Write first; only adopt the new layer once it is safely on disk.
        try Self.writeObject(nextLayer, to: userFileURL)
        userLayer = nextLayer
        var warnings: [String] = []
        cached = Self.resolve(user: userLayer, managed: managedLayer, warnings: &warnings)
        return cached
    }

    /// Clears every user setting (managed settings remain).
    public func resetUserSettings() throws {
        lock.lock(); defer { lock.unlock() }
        userLayer = [:]
        try? FileManager.default.removeItem(at: userFileURL)
        var warnings: [String] = []
        cached = Self.resolve(user: userLayer, managed: managedLayer, warnings: &warnings)
    }

    // MARK: - Pure helpers (internal for tests)

    static func resolve(user: [String: Any], managed: [String: Any], warnings: inout [String]) -> AppConfig {
        let defaults = (try? toObject(AppConfig())) ?? [:]
        let base = merge(defaults, user)
        if let config = try? fromObject(merge(base, managed)) { return config }
        // Ignore only the managed values that don't fit; keep the user's settings and the valid managed ones.
        let goodManaged = dropInvalidLeaves(of: managed, base: base, top: [:])
        if goodManaged.removed > 0 {
            warnings.append("managed config had \(goodManaged.removed) invalid value(s) that were ignored")
        }
        if let config = try? fromObject(merge(base, goodManaged.layer)) { return config }
        warnings.append("settings had invalid values and were ignored")
        if let config = try? fromObject(merge(defaults, goodManaged.layer)) { return config }
        return AppConfig()
    }

    /// Removes leaf values from `user` that make the config undecodable (e.g. a string where a number
    /// belongs), one at a time, so one bad value never discards the user's other settings.
    static func sanitize(user: [String: Any], managed: [String: Any]) -> (layer: [String: Any], removed: Int) {
        let defaults = (try? toObject(AppConfig())) ?? [:]
        if (try? fromObject(merge(merge(defaults, user), managed))) != nil { return (user, 0) }
        // Judge user values against the managed values that are themselves valid, so a broken managed file
        // never causes the user's own settings to be discarded.
        let goodManaged = dropInvalidLeaves(of: managed, base: defaults, top: [:]).layer
        return dropInvalidLeaves(of: user, base: defaults, top: goodManaged)
    }

    /// Drops each leaf of `layer` that, applied alone on top of `base` (and under `top`), fails to decode.
    static func dropInvalidLeaves(of layer: [String: Any], base: [String: Any], top: [String: Any]) -> (layer: [String: Any], removed: Int) {
        if (try? fromObject(merge(merge(base, layer), top))) != nil { return (layer, 0) }
        let paths = leafPaths(layer)
        var kept = layer
        var removed = 0
        for path in paths.sorted() {
            let single = removing(paths: paths.subtracting([path]), from: layer)
            if (try? fromObject(merge(merge(base, single), top))) == nil {
                kept = removing(paths: [path], from: kept)
                removed += 1
            }
        }
        if (try? fromObject(merge(merge(base, kept), top))) == nil {
            return ([:], max(removed, 1))
        }
        return (kept, removed)
    }

    static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in overlay {
            if value is NSNull {
                out[key] = nil
            } else if let sub = value as? [String: Any], let baseSub = out[key] as? [String: Any] {
                out[key] = merge(baseSub, sub)
            } else {
                out[key] = value
            }
        }
        return out
    }

    static func diff(from old: [String: Any], to new: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, newValue) in new {
            let oldValue = old[key]
            if let newSub = newValue as? [String: Any], let oldSub = oldValue as? [String: Any] {
                let sub = diff(from: oldSub, to: newSub)
                if !sub.isEmpty { out[key] = sub }
            } else if !jsonEqual(oldValue, newValue) {
                out[key] = newValue
            }
        }
        // Optionals encode as absent keys; record a cleared value explicitly so it overrides the layer below.
        for key in old.keys where new[key] == nil {
            out[key] = NSNull()
        }
        return out
    }

    static func leafPaths(_ object: [String: Any], prefix: String = "") -> Set<String> {
        var out = Set<String>()
        for (key, value) in object {
            let path = prefix.isEmpty ? key : prefix + "." + key
            if let sub = value as? [String: Any], !sub.isEmpty {
                out.formUnion(leafPaths(sub, prefix: path))
            } else {
                out.insert(path)
            }
        }
        return out
    }

    static func removing(paths: Set<String>, from object: [String: Any], prefix: String = "") -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in object {
            let path = prefix.isEmpty ? key : prefix + "." + key
            if paths.contains(path) { continue }
            if let sub = value as? [String: Any] {
                let kept = removing(paths: paths, from: sub, prefix: path)
                if !kept.isEmpty { out[key] = kept }
            } else {
                out[key] = value
            }
        }
        return out
    }

    private static func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a?, b?):
            guard JSONSerialization.isValidJSONObject([a]), JSONSerialization.isValidJSONObject([b]),
                  let da = try? JSONSerialization.data(withJSONObject: [a], options: [.sortedKeys]),
                  let db = try? JSONSerialization.data(withJSONObject: [b], options: [.sortedKeys]) else { return false }
            return da == db
        }
    }

    static func toObject(_ config: AppConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func fromObject(_ object: [String: Any]) throws -> AppConfig {
        let data = try JSONSerialization.data(withJSONObject: object)
        var config = try JSONDecoder().decode(AppConfig.self, from: data)
        // A retired model in saved settings is swapped for its replacement (once each in the fallbacks).
        config.vision.modelID = VisionModelCatalog.current(config.vision.modelID)
        var seen = Set<String>()
        config.vision.fallbackModelIDs = config.vision.fallbackModelIDs.map(VisionModelCatalog.current).filter { seen.insert($0).inserted }
        return config
    }

    private static func readObject(at url: URL, warnings: inout [String], label: String, mustBeReadable: Bool = false) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            if mustBeReadable { warnings.append("\(label) file exists but cannot be read") }
            return [:]
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            warnings.append("\(label) file is not valid JSON and was ignored")
            return [:]
        }
        return object
    }

    private static func writeObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
