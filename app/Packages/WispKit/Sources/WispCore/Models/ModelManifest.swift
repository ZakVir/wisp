import CryptoKit
import Foundation

/// The signed list of on-device models Wisp installs (speech-to-text and text-to-speech).
///
/// Wire format: `manifest.json` (this type, UTF-8 JSON) plus `manifest.json.sig` (base64 Ed25519 signature of
/// the exact manifest bytes). The app trusts only manifests signed by `ManifestTrust.publicKeys`, and every
/// file is pinned by SHA-256, so neither the host nor a mirror can substitute content.
public struct ModelManifest: Codable, Equatable, Sendable {
    /// Format version of this document. The app refuses schemas it does not understand.
    public var schema: Int
    /// Monotonic release identifier, e.g. "2026.10.01.1". Compared to decide whether a remote manifest is newer.
    public var manifestVersion: String
    public var models: [ModelEntry]

    public static let supportedSchema = 1

    public init(schema: Int = ModelManifest.supportedSchema, manifestVersion: String, models: [ModelEntry]) {
        self.schema = schema
        self.manifestVersion = manifestVersion
        self.models = models
    }

    public func model(id: String) -> ModelEntry? { models.first { $0.id == id } }
}

public struct ModelEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case speechToText, textToSpeech }

    /// Stable identifier, e.g. "moonshine-small-streaming-en". Also the folder name on disk.
    public var id: String
    /// Version of this model's files, e.g. "quantized_26_08_21". Installed side by side with older versions.
    public var version: String
    public var kind: Kind
    public var displayName: String
    /// Which runtime loads these files ("moonshine-ort", "kokoro-coreml").
    public var runtime: String
    public var license: String
    public var licenseURL: String
    /// Minimum macOS version, "15.0".
    public var minMacOS: String
    public var files: [ModelFile]

    public init(id: String, version: String, kind: Kind, displayName: String, runtime: String, license: String,
                licenseURL: String, minMacOS: String, files: [ModelFile]) {
        self.id = id; self.version = version; self.kind = kind; self.displayName = displayName
        self.runtime = runtime; self.license = license; self.licenseURL = licenseURL; self.minMacOS = minMacOS
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ModelFile: Codable, Equatable, Sendable, Hashable {
    /// Path relative to the model's version folder, e.g. "kokoro_5s.mlmodelc/weights/weight.bin".
    public var path: String
    /// Primary download URL (https).
    public var url: String
    public var size: Int64
    /// Lowercase hex SHA-256 of the file contents.
    public var sha256: String

    public init(path: String, url: String, size: Int64, sha256: String) {
        self.path = path; self.url = url; self.size = size; self.sha256 = sha256
    }
}

/// Reasons a manifest is rejected. Messages are safe to log.
public enum ManifestError: Error, Equatable, Sendable {
    case badSignature
    case unreadable(String)
    case unsupportedSchema(Int)
    case invalid(String)
}

/// Public keys allowed to sign model manifests (raw Ed25519, base64). More than one allows key rotation.
public enum ManifestTrust {
    public static let publicKeys: [String] = [
        // Wisp model manifest key #1 (private half kept offline in the maintainer's Keychain).
        "U0QFFT8rIzMSRWl5RC6hYK6gqDZZpOgNNauJdSEfnuE=",
    ]
}

public enum ManifestCodec {
    /// Verifies the signature against `trustedKeys`, then parses and validates. The order matters: never parse
    /// (or act on) bytes whose signature has not been checked.
    public static func load(manifestData: Data, signatureBase64: String,
                            trustedKeys: [String] = ManifestTrust.publicKeys) throws -> ModelManifest {
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ManifestError.badSignature
        }
        let verified = trustedKeys.contains { keyString in
            guard let raw = Data(base64Encoded: keyString),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(signature, for: manifestData)
        }
        guard verified else { throw ManifestError.badSignature }
        return try parse(manifestData)
    }

    /// Parses and validates without checking a signature (tests and the signing tool only).
    public static func parse(_ data: Data) throws -> ModelManifest {
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ManifestError.unreadable(String(describing: error).prefix(200).description)
        }
        guard manifest.schema == ModelManifest.supportedSchema else { throw ManifestError.unsupportedSchema(manifest.schema) }
        try validate(manifest)
        return manifest
    }

    static func validate(_ m: ModelManifest) throws {
        guard !m.manifestVersion.isEmpty else { throw ManifestError.invalid("empty manifestVersion") }
        var ids = Set<String>()
        for model in m.models {
            guard isSafeComponent(model.id), isSafeComponent(model.version) else {
                throw ManifestError.invalid("unsafe id or version: \(model.id)")
            }
            guard ids.insert(model.id).inserted else { throw ManifestError.invalid("duplicate model id \(model.id)") }
            guard !model.files.isEmpty else { throw ManifestError.invalid("model \(model.id) has no files") }
            var paths = Set<String>()
            for file in model.files {
                guard isSafeRelativePath(file.path) else { throw ManifestError.invalid("unsafe path \(file.path)") }
                guard paths.insert(file.path).inserted else { throw ManifestError.invalid("duplicate path \(file.path)") }
                guard let url = URL(string: file.url), url.scheme == "https", url.host != nil else {
                    throw ManifestError.invalid("file URL must be https: \(file.path)")
                }
                guard file.size > 0 else { throw ManifestError.invalid("bad size for \(file.path)") }
                guard file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw ManifestError.invalid("bad sha256 for \(file.path)")
                }
            }
        }
    }

    /// One path component: letters, digits, '.', '_', '-'; not "." or "..".
    static func isSafeComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != "..", s.count <= 128 else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }

    /// Relative path made only of safe components (no "..", no leading "/", no empty segments).
    static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.hasPrefix("/"), p.count <= 512 else { return false }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { isSafeComponent(String($0)) }
    }

    /// Lexicographic comparison of dotted numeric versions ("2026.10.01.2" > "2026.10.01.1").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum SHA256Hex {
    /// Streams a file through SHA-256 in 1 MiB chunks (constant memory for large weights).
    public static func file(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
