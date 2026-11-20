import Foundation

/// Where model files live on disk.
///
///     <root>/<model id>/<version>/<file path>      installed, verified files
///     <root>/<model id>/<version>/.installed.json  written last: an install without it is not trusted
///     <root>/.staging/<model id>/<version>/…       downloads in progress (atomically renamed into place)
public struct ModelLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func versionDirectory(_ model: ModelEntry) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true).appendingPathComponent(model.version, isDirectory: true)
    }

    public func stagingDirectory(_ model: ModelEntry) -> URL {
        root.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
            .appendingPathComponent(model.version, isDirectory: true)
    }

    public func marker(_ model: ModelEntry) -> URL {
        versionDirectory(model).appendingPathComponent(InstallMarker.fileName)
    }

    /// Every version folder present for a model id (installed or partial).
    public func installedVersions(of id: String) -> [String] {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { !$0.hasPrefix(".") }.sorted()
    }
}

/// Written after every file of a model version was verified; its presence is what "installed" means.
public struct InstallMarker: Codable, Equatable, Sendable {
    public static let fileName = ".installed.json"
    public var modelID: String
    public var version: String
    public var manifestVersion: String
    public var files: [String: String] // path → sha256 verified at install time
    public var installedAt: Date

    public init(modelID: String, version: String, manifestVersion: String, files: [String: String], installedAt: Date) {
        self.modelID = modelID; self.version = version; self.manifestVersion = manifestVersion
        self.files = files; self.installedAt = installedAt
    }

    /// True when this marker vouches for exactly the files the manifest pins.
    public func matches(_ model: ModelEntry) -> Bool {
        modelID == model.id && version == model.version
            && files.count == model.files.count
            && model.files.allSatisfy { files[$0.path] == $0.sha256 }
    }
}

/// User-visible state of one model.
public enum ModelState: Equatable, Sendable {
    case notInstalled
    /// `fraction` 0...1; `bytes`/`total` for "420 MB of 1.5 GB".
    case downloading(fraction: Double, bytes: Int64, total: Int64)
    case verifying
    /// Loading/warming the model so first use is fast.
    case preparing
    case ready(version: String)
    case failed(ModelFailure)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .preparing: return true
        default: return false
        }
    }
}

/// Every way an install can fail, each with plain copy and whether retrying makes sense.
public enum ModelFailure: Error, Equatable, Sendable {
    case offline
    case hostUnreachable(String)
    case hostBlocked(String)
    case interrupted
    case hashMismatch(String)
    case diskFull(neededBytes: Int64, availableBytes: Int64)
    case server(Int)
    case manifestRejected(String)
    case unsupportedMacOS(String)
    case blockedByPolicy(String)
    case other(String)

    public var userMessage: String {
        switch self {
        case .offline:
            return "You're offline. The speech models will download when you're back online."
        case .hostUnreachable:
            return "Can't reach the download server right now. Wisp will keep trying."
        case .hostBlocked:
            return "This network is blocking the download. Try a different Wi-Fi network."
        case .interrupted:
            return "The download was interrupted. It will pick up where it left off."
        case .hashMismatch:
            return "A downloaded file didn't match its fingerprint, so Wisp threw it away. Try again."
        case .diskFull(let needed, let available):
            guard needed > 0 else { return "Your Mac is out of storage space. Free up some space, then try again." }
            let fmt = ByteCountFormatter()
            return "Not enough space. The speech models need \(fmt.string(fromByteCount: needed)); \(fmt.string(fromByteCount: available)) is free."
        case .server(let code):
            return "The download server had a problem (\(code)). Wisp will try again."
        case .manifestRejected:
            return "Wisp couldn't verify its speech files, so nothing was downloaded. Update Wisp to the latest version, then try again."
        case .unsupportedMacOS(let need):
            return "This speech model needs macOS \(need) or later."
        case .blockedByPolicy(let message):
            return message
        case .other:
            return "Something went wrong while installing the speech models. Try again."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .manifestRejected, .unsupportedMacOS, .blockedByPolicy: return false
        default: return true
        }
    }

    /// Classifies a URLSession/file-system error.
    public static func classify(_ error: Error) -> ModelFailure {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
                 NSURLErrorInternationalRoamingOff:
                return ns.code == NSURLErrorNetworkConnectionLost ? .interrupted : .offline
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .hostUnreachable(ns.localizedDescription)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected,
                 NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .hostBlocked(ns.localizedDescription)
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
                return .hostUnreachable(ns.localizedDescription)
            case NSURLErrorCancelled:
                return .interrupted
            case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile:
                return .diskFull(neededBytes: 0, availableBytes: 0)
            default:
                return .other("url \(ns.code)")
            }
        }
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return .diskFull(neededBytes: 0, availableBytes: 0)
        }
        return .other("\(ns.domain) \(ns.code)")
    }

    /// Classifies an HTTP status.
    public static func classify(httpStatus code: Int) -> ModelFailure {
        switch code {
        case 401, 403, 407, 451: return .hostBlocked("HTTP \(code)")
        default: return .server(code)
        }
    }
}

/// Retry timing: exponential backoff with jitter, capped.
public struct Backoff: Sendable {
    public var base: Double = 2
    public var cap: Double = 300
    public var jitter: Double = 0.2

    public init(base: Double = 2, cap: Double = 300, jitter: Double = 0.2) {
        self.base = base; self.cap = cap; self.jitter = jitter
    }

    /// Delay before retry number `attempt` (1-based). `random` in 0...1 for testability.
    public func delay(attempt: Int, random: Double = Double.random(in: 0...1)) -> Double {
        let raw = min(cap, base * pow(2, Double(max(0, attempt - 1))))
        return raw * (1 - jitter + 2 * jitter * random)
    }
}

/// Disk space check: the download needs room for the files plus a safety margin (staging + filesystem slack).
public enum DiskSpace {
    public static let margin: Int64 = 200 * 1024 * 1024

    public static func required(for bytes: Int64) -> Int64 { bytes + bytes / 10 + margin }

    public static func available(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Where a file can be fetched from, in order: the pre-provisioned offline folder, the primary URL, mirrors.
public enum FileSources {
    public static func candidates(for file: ModelFile, model: ModelEntry, mirrors: [String]) -> [URL] {
        var out: [URL] = []
        if let primary = URL(string: file.url) { out.append(primary) }
        for base in mirrors {
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            if let url = URL(string: "\(trimmed)/\(model.id)/\(model.version)/\(file.path)"), url.scheme == "https" {
                out.append(url)
            }
        }
        return out
    }

    /// The file inside an offline folder that mirrors the on-disk layout (`<folder>/<id>/<version>/<path>`).
    public static func offlineCandidate(for file: ModelFile, model: ModelEntry, folder: String?) -> URL? {
        guard let folder, !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(model.id).appendingPathComponent(model.version).appendingPathComponent(file.path)
    }
}
