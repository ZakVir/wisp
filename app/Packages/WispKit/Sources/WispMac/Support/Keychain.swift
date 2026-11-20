import CryptoKit
import Foundation
import IOKit
import Security
import WispCore

/// Stores secrets (vision provider API keys) encrypted on this Mac, without ever showing a system prompt.
///
/// 1. The data-protection Keychain (no access prompts, ever) when the app is entitled for it.
/// 2. Otherwise an AES-GCM encrypted file in Application Support (mode 0600). Its key is derived from this Mac's
///    hardware UUID and a random per-install salt, so a copied file can't be decrypted elsewhere.
/// The legacy login Keychain is deliberately never used: it shows "wants to access your keychain" dialogs
/// whenever the app's signature changes (observed during development).
public enum Keychain {
    public static let service = "com.zakvirani.wisp"

    public static func read(_ account: String) -> String? {
        if let value = DataProtectionKeychain.read(account) { return value }
        return EncryptedSecretFile.read(account)
    }

    @discardableResult
    public static func write(_ value: String, account: String) -> Bool {
        if DataProtectionKeychain.write(value, account: account) {
            EncryptedSecretFile.delete(account)
            return true
        }
        return EncryptedSecretFile.write(value, account: account)
    }

    @discardableResult
    public static func delete(_ account: String) -> Bool {
        DataProtectionKeychain.delete(account)
        return EncryptedSecretFile.delete(account)
    }
}

/// Data-protection keychain (iOS-style): needs a keychain-access-group entitlement; returns nil/false otherwise.
enum DataProtectionKeychain {
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Keychain.service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        var add = base(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

/// AES-GCM encrypted secrets file bound to this Mac.
enum EncryptedSecretFile {
    private static var directory: URL { AppPaths.applicationSupport.appendingPathComponent("Secrets", isDirectory: true) }
    private static func url(_ account: String) -> URL { directory.appendingPathComponent(account + ".sealed") }

    private static let lock = NSLock()

    private static func key() -> SymmetricKey? {
        lock.withLock {
            let saltURL = directory.appendingPathComponent(".salt")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            // Fail closed: without this Mac's hardware UUID there is no key (never a guessable constant).
            guard let uuid = hardwareUUID(), !uuid.isEmpty else { return nil }
            var salt = (try? Data(contentsOf: saltURL)) ?? Data()
            if salt.count != 32 {
                // Never replace a salt that sealed files depend on (that would silently destroy them).
                let sealed = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains { $0.hasSuffix(".sealed") } ?? false
                guard !sealed || !FileManager.default.fileExists(atPath: saltURL.path) else { return nil }
                salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                guard FileManager.default.createFile(atPath: saltURL.path, contents: salt, attributes: [.posixPermissions: 0o600]) else { return nil }
            }
            return derive(uuid: uuid, salt: salt)
        }
    }

    private static func derive(uuid: String, salt: Data) -> SymmetricKey {
        let machine = Data(uuid.utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: machine), salt: salt,
                                      info: Data("com.zakvirani.wisp.secrets.v1".utf8), outputByteCount: 32)
    }

    static func read(_ account: String) -> String? {
        guard let sealed = try? Data(contentsOf: url(account)), let key = key(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key, authenticating: Data(account.utf8)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) -> Bool {
        // The account name is authenticated too, so a sealed file can't be swapped in for another account.
        guard let key = key(),
              let sealed = try? AES.GCM.seal(Data(value.utf8), using: key, authenticating: Data(account.utf8)).combined else { return false }
        // Write to a 0600 temp file first, then rename (never briefly world-readable).
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: sealed, attributes: [.posixPermissions: 0o600]) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(url(account), withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let u = url(account)
        guard FileManager.default.fileExists(atPath: u.path) else { return true }
        return (try? FileManager.default.removeItem(at: u)) != nil
    }

    /// IOPlatformUUID: stable per Mac, not readable by other machines.
    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

/// Vision providers Wisp supports.
public enum VisionProvider: String, CaseIterable, Identifiable, Sendable {
    case nvidiaNIM = "nvidia-nim"
    case openAICompatible = "openai-compatible"
    case anthropic = "anthropic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nvidiaNIM: return "NVIDIA (free)"
        case .openAICompatible: return "Custom (OpenAI-compatible)"
        case .anthropic: return "Anthropic (Claude)"
        }
    }

    public var keychainAccount: String {
        switch self {
        case .nvidiaNIM: return "nvidia-nim-api-key"
        case .openAICompatible: return "openai-compatible-api-key"
        case .anthropic: return "anthropic-api-key"
        }
    }

    /// Environment variable checked when no key is saved (developer convenience; never required).
    public var environmentVariable: String {
        switch self {
        case .nvidiaNIM: return "NVIDIA_API_KEY"
        case .openAICompatible: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .nvidiaNIM: return "https://integrate.api.nvidia.com/v1"
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    /// The model a fresh choice of this provider starts with ("" = the user names one).
    public var defaultModelID: String {
        switch self {
        case .nvidiaNIM: return VisionSettings.defaultModelID
        case .anthropic: return VisionModelCatalog.defaultClaudeModelID
        case .openAICompatible: return ""
        }
    }

    /// The request format the provider speaks.
    public var wire: VisionClient.Wire { self == .anthropic ? .anthropicMessages : .openAIChat }

    /// Models offered in Settings (empty: the user types or finds one).
    public var catalog: [VisionModelInfo] {
        switch self {
        case .nvidiaNIM: return VisionModelCatalog.nim
        case .anthropic: return VisionModelCatalog.claude
        case .openAICompatible: return []
        }
    }

    public init(configID: String) {
        self = VisionProvider(rawValue: configID) ?? .nvidiaNIM
    }

    /// A custom server may need no key (Ollama, LM Studio and other local servers).
    public var requiresKey: Bool { self != .openAICompatible }
}

/// Reads and saves provider API keys.
public enum APIKeyStore {
    public static func key(for provider: VisionProvider) -> String? {
        if let saved = Keychain.read(provider.keychainAccount), !saved.isEmpty { return saved }
        if let env = ProcessInfo.processInfo.environment[provider.environmentVariable], !env.isEmpty { return env }
        return nil
    }

    public static func hasKey(for provider: VisionProvider) -> Bool { key(for: provider) != nil }

    /// Wisp can ask its AI: NVIDIA needs a key; a custom server needs an address and a model (a key only if it asks).
    public static func isConnected(_ vision: VisionSettings) -> Bool {
        let provider = VisionProvider(configID: vision.providerID)
        if provider.requiresKey { return hasKey(for: provider) }
        return URL(string: vision.baseURL)?.host?.isEmpty == false && !vision.modelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when the key comes from the Keychain (saved in Settings), not just the environment.
    public static func isSaved(for provider: VisionProvider) -> Bool {
        Keychain.read(provider.keychainAccount)?.isEmpty == false
    }

    @discardableResult
    public static func save(_ key: String, for provider: VisionProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Keychain.write(trimmed, account: provider.keychainAccount)
    }

    public static func clear(for provider: VisionProvider) {
        Keychain.delete(provider.keychainAccount)
    }

    /// Kept for call sites written before multiple providers existed.
    public static func nimKey() -> String? { key(for: .nvidiaNIM) }
}
