import CryptoKit
import Foundation

/// Cryptographically authenticated OTA manifest payload (signed with Ed25519 over canonical JSON bytes).
struct OTAManifestPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let keyID: String
    let channel: String
    let bundleID: String
    let engineBundleID: String
    let version: String
    let build: Int
    let arch: String
    let minMacOS: String
    let archiveSize: Int64
    let archiveSHA256: String
    let downloadURL: String
    let publishedAt: String
    let expiresAt: String
    let releaseNotes: String

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct SignedOTAManifest: Codable, Equatable, Sendable {
    let payload: OTAManifestPayload
    let signature: String // Base64-encoded 64-byte Ed25519 signature over payload.canonicalData()
}

enum OTAValidationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unknownKeyID(String)
    case invalidSignature
    case wrongBundleID(String)
    case wrongEngineBundleID(String)
    case wrongChannel(String)
    case incompatibleArch(expected: String, got: String)
    case unsupportedOS(required: String)
    case expiredManifest(String)
    case notNewer(currentBuild: Int, candidateBuild: Int)
    case untrustedDownloadURL(String)
    case invalidArchiveSize(Int64)
    case invalidSHA256Format
    case checksumMismatch
    case unsafeArchiveEntry(String)
    case readOnlyOrTranslocatedLocation(String)
    case signatureVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "Unsupported OTA schema v\(v)"
        case .unknownKeyID(let k): return "Untrusted OTA signing key: \(k)"
        case .invalidSignature: return "OTA manifest Ed25519 signature verification failed"
        case .wrongBundleID(let id): return "Unexpected OTA bundle ID: \(id)"
        case .wrongEngineBundleID(let id): return "Unexpected OTA engine bundle ID: \(id)"
        case .wrongChannel(let c): return "Unexpected OTA release channel: \(c)"
        case .incompatibleArch(let e, let g): return "Incompatible architecture (expected \(e), got \(g))"
        case .unsupportedOS(let req): return "Requires macOS \(req) or newer"
        case .expiredManifest(let exp): return "OTA manifest expired at \(exp)"
        case .notNewer(let cur, let cand): return "Build \(cand) is not newer than current build \(cur)"
        case .untrustedDownloadURL(let u): return "Untrusted OTA download URL: \(u)"
        case .invalidArchiveSize(let s): return "Archive size out of allowed bounds (\(s) bytes)"
        case .invalidSHA256Format: return "Invalid SHA-256 hex digest in OTA manifest"
        case .checksumMismatch: return "Downloaded archive SHA-256 mismatch"
        case .unsafeArchiveEntry(let p): return "Unsafe archive entry rejected: \(p)"
        case .readOnlyOrTranslocatedLocation(let reason): return reason
        case .signatureVerificationFailed(let reason): return reason
        }
    }
}

enum OTAConfig {
    static let manifestURL = URL(string: "https://github.com/HazelKahlil/DisplayVolume/releases/latest/download/ota-manifest.json")!
    static let releasesPageURL = URL(string: "https://github.com/HazelKahlil/DisplayVolume/releases/latest")!
    static let allowedDownloadPrefix = "https://github.com/HazelKahlil/DisplayVolume/releases/download/"
    static let allowedRedirectHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com"
    ]
    static let channel = "stable"
    static let minArchiveBytes: Int64 = 64 * 1024
    static let maxArchiveBytes: Int64 = 50 * 1024 * 1024

    /// Embedded Ed25519 public trust roots keyed by `keyID` (supports seamless key rotation).
    static let trustedPublicKeys: [String: String] = [
        "dv-ota-2026-11": "KooPkLdy09z9NAz7E31x0wOUUzJaw72CbEIF1HLb5qI="
    ]

    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

enum OTAManifestVerifier {
    static func verify(
        _ signed: SignedOTAManifest,
        currentBuild: Int,
        currentOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        currentArch: String = OTAConfig.currentArch,
        now: Date = Date(),
        trustedKeys: [String: String] = OTAConfig.trustedPublicKeys
    ) throws -> OTAManifestPayload {
        let p = signed.payload
        guard p.schemaVersion == 1 else { throw OTAValidationError.unsupportedSchema(p.schemaVersion) }
        guard let pubB64 = trustedKeys[p.keyID],
              let pubRaw = Data(base64Encoded: pubB64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else {
            throw OTAValidationError.unknownKeyID(p.keyID)
        }
        guard let sigData = Data(base64Encoded: signed.signature),
              let canonical = try? p.canonicalData(),
              publicKey.isValidSignature(sigData, for: canonical) else {
            throw OTAValidationError.invalidSignature
        }

        guard p.bundleID == VolumeIPC.suiteName else { throw OTAValidationError.wrongBundleID(p.bundleID) }
        guard p.engineBundleID == VolumeIPC.engineBundleID else { throw OTAValidationError.wrongEngineBundleID(p.engineBundleID) }
        guard p.channel == OTAConfig.channel else { throw OTAValidationError.wrongChannel(p.channel) }
        guard p.arch == currentArch || p.arch == "universal" else {
            throw OTAValidationError.incompatibleArch(expected: currentArch, got: p.arch)
        }
        guard satisfiesMinOS(current: currentOS, required: p.minMacOS) else {
            throw OTAValidationError.unsupportedOS(required: p.minMacOS)
        }

        let iso = ISO8601DateFormatter()
        guard let expires = iso.date(from: p.expiresAt), expires > now else {
            throw OTAValidationError.expiredManifest(p.expiresAt)
        }

        guard p.build > currentBuild else {
            throw OTAValidationError.notNewer(currentBuild: currentBuild, candidateBuild: p.build)
        }

        guard p.downloadURL.hasPrefix(OTAConfig.allowedDownloadPrefix),
              let parsedURL = URL(string: p.downloadURL),
              parsedURL.scheme == "https",
              parsedURL.host == "github.com" else {
            throw OTAValidationError.untrustedDownloadURL(p.downloadURL)
        }

        guard p.archiveSize >= OTAConfig.minArchiveBytes && p.archiveSize <= OTAConfig.maxArchiveBytes else {
            throw OTAValidationError.invalidArchiveSize(p.archiveSize)
        }

        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard p.archiveSHA256.count == 64,
              p.archiveSHA256.unicodeScalars.allSatisfy({ hexSet.contains($0) }) else {
            throw OTAValidationError.invalidSHA256Format
        }

        return p
    }

    static func satisfiesMinOS(current: OperatingSystemVersion, required: String) -> Bool {
        let parts = required.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return false }
        let reqMajor = parts[0]
        let reqMinor = parts.count > 1 ? parts[1] : 0
        let reqPatch = parts.count > 2 ? parts[2] : 0
        if current.majorVersion != reqMajor { return current.majorVersion > reqMajor }
        if current.minorVersion != reqMinor { return current.minorVersion > reqMinor }
        return current.patchVersion >= reqPatch
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pure zip entry & symlink safety checker to prevent zip-slip path traversal and archive bombs.
enum OTAArchiveSafety {
    static let maxEntryCount = 500

    static func validateEntryPaths(_ entries: [String], expectedRoot: String = "DisplayVolume.app") throws {
        guard !entries.isEmpty, entries.count <= maxEntryCount else {
            throw OTAValidationError.unsafeArchiveEntry("Entry count out of bounds (\(entries.count))")
        }
        var seenLowercase = Set<String>()
        var sawMainExecutable = false
        for raw in entries {
            if raw.isEmpty || raw.hasPrefix("/") || raw.contains("\\") || raw.contains("\0") {
                throw OTAValidationError.unsafeArchiveEntry(raw)
            }
            let components = raw.split(separator: "/", omittingEmptySubsequences: false)
            if components.contains("..") {
                throw OTAValidationError.unsafeArchiveEntry(raw)
            }
            guard components.first == Substring(expectedRoot) else {
                throw OTAValidationError.unsafeArchiveEntry(raw)
            }
            let normalized = raw.lowercased()
            if !seenLowercase.insert(normalized).inserted {
                throw OTAValidationError.unsafeArchiveEntry("Case collision: \(raw)")
            }
            if raw == "\(expectedRoot)/Contents/MacOS/DisplayVolume" {
                sawMainExecutable = true
            }
        }
        if !sawMainExecutable {
            throw OTAValidationError.unsafeArchiveEntry("Missing \(expectedRoot)/Contents/MacOS/DisplayVolume")
        }
    }

    /// Recursively verifies that extracted symlinks never escape the extracted bundle root.
    static func validateExtractedTree(at appURL: URL) throws {
        let rootResolved = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw OTAValidationError.unsafeArchiveEntry("Cannot inspect extracted bundle")
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: item.path)
                if target.hasPrefix("/") {
                    throw OTAValidationError.unsafeArchiveEntry("Absolute symlink: \(item.lastPathComponent)")
                }
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == rootResolved || resolved.hasPrefix(rootResolved + "/") else {
                    throw OTAValidationError.unsafeArchiveEntry("Escaping symlink: \(item.lastPathComponent)")
                }
            }
        }
    }
}

/// Preflight check rejecting read-only DMG mounts, App Translocation, and non-writable install directories.
enum OTAInstallPreflight {
    static func validateInstallTarget(bundleURL: URL) throws {
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") {
            throw OTAValidationError.readOnlyOrTranslocatedLocation(
                L10n.text("当前应用位于系统临时隔离目录，请先拖入「应用程序」文件夹后再使用在线更新。", "App is running from App Translocation. Move DisplayVolume to Applications before updating.")
            )
        }
        if path.hasPrefix("/Volumes/") {
            throw OTAValidationError.readOnlyOrTranslocatedLocation(
                L10n.text("当前应用正在磁盘镜像（DMG）中运行，请先拖入「应用程序」后再更新。", "App is running from a mounted volume. Move DisplayVolume to Applications before updating.")
            )
        }
        let parent = bundleURL.deletingLastPathComponent()
        if let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            throw OTAValidationError.readOnlyOrTranslocatedLocation(
                L10n.text("当前应用所在卷为只读，无法原地更新。", "App resides on a read-only volume.")
            )
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw OTAValidationError.readOnlyOrTranslocatedLocation(
                L10n.text("没有目录写入权限（\(parent.path)），请前往 GitHub 下载最新安装包。", "Directory \(parent.path) is not writable. Download the DMG from GitHub Releases.")
            )
        }
    }
}
