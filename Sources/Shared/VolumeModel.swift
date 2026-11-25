import Foundation
import Security

struct DeviceVolumeProfile: Codable, Equatable, Sendable {
    var volume: Int
    var volumeLimit: Int
    var muted: Bool
    var enabled: Bool

    static let defaultSafe = DeviceVolumeProfile(volume: 50, volumeLimit: 100, muted: false, enabled: true)
}

struct VolumeState: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 3

    enum Phase: String, Codable, Sendable {
        case idle
        case checking
        case active
    }

    enum TriggerSource: String, Codable, Sendable {
        case mediaKey
        case hotkey
        case scroll
        case slider
        case preset
        case system
    }

    var protocolVersion: Int
    var engineBuild: Int
    var engineInstanceID: String
    var stateSequence: UInt64
    var routeGeneration: UInt64
    var enginePID: Int32
    var phase: Phase
    var deviceUID: String?
    var deviceName: String?
    var transportLabel: String?
    var isLockedOutput: Bool
    var isControllable: Bool
    var volume: Int
    var volumeLimit: Int
    var muted: Bool
    var enabled: Bool
    var verifiedCapture: Bool
    var mediaKeysAuthorized: Bool
    var mediaKeysActive: Bool
    var shortcutsAvailable: Bool
    var micHotkeyAvailable: Bool
    var showOSD: Bool
    var showMenuBarPercent: Bool
    var scrollOnIconEnabled: Bool
    var lastTriggerSource: TriggerSource?
    var lastTriggerNonce: UInt64
    var message: String?

    var shownVolume: Int {
        muted ? 0 : min(volume, volumeLimit)
    }

    var atCeiling: Bool {
        !muted && volume >= volumeLimit
    }
}

/// Authenticated Mach XPC service interface between DisplayVolume UI and DisplayVolumeEngine LaunchAgent.
/// All mutating commands (output volume, limits, mic gain/mute, preferences, media-key ownership) run over
/// this code-signing-verified XPC channel rather than spoofable DistributedNotificationCenter broadcasts.
@objc(DisplayVolumeEngineXPCProtocol)
protocol DisplayVolumeEngineXPCProtocol {
    func ping(withReply reply: @escaping (Int, Int, String) -> Void)
    func fetchState(withReply reply: @escaping (Data?) -> Void)
    func setVolume(_ value: Int, deviceUID: String, isDragging: Bool, source: String, withReply reply: @escaping (Data?) -> Void)
    func stepVolume(_ delta: Int, deviceUID: String, source: String, withReply reply: @escaping (Data?) -> Void)
    func setLimit(_ limit: Int, deviceUID: String, isDragging: Bool, withReply reply: @escaping (Data?) -> Void)
    func toggleOutputMute(deviceUID: String, source: String, withReply reply: @escaping (Data?) -> Void)
    func setEnabled(_ enabled: Bool, withReply reply: @escaping (Data?) -> Void)
    func setMicVolume(_ value: Int, deviceUID: String, isDragging: Bool, withReply reply: @escaping (Bool, Data?) -> Void)
    func toggleMicMute(deviceUID: String, showOSD: Bool, withReply reply: @escaping (Bool, Data?) -> Void)
    func setPreference(_ key: String, flag: Bool, withReply reply: @escaping (Data?) -> Void)
    func setUIMediaKeysActive(_ active: Bool, clientInstanceID: String, withReply reply: @escaping (Data?) -> Void)
    func requestAccessibility(withReply reply: @escaping (Data?) -> Void)
    func reverifyCapture(withReply reply: @escaping (Data?) -> Void)
}

enum VolumeIPC {
    static let suiteName = "com.hazelkahlil.DisplayVolume"
    static let legacySuiteName = "local.kahlil.RedmiVolume"
    static let engineBundleID = "com.hazelkahlil.DisplayVolume.Engine"
    static let legacyEngineBundleID = "local.kahlil.RedmiVolume.Engine"
    static let xpcMachServiceName = "com.hazelkahlil.DisplayVolume.Engine.xpc"

    // Read-only state change notification (carries no authority; UI still validates / reconciles via XPC).
    static let changed = Notification.Name("com.hazelkahlil.DisplayVolume.engine-state")

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DisplayVolume", isDirectory: true)
    static let stateFile = directory.appendingPathComponent("state.json")
    static let installLockFile = directory.appendingPathComponent(".install.lock")
    static let maxStateFileBytes = 65_536

    static func makeXPCInterface() -> NSXPCInterface {
        NSXPCInterface(with: DisplayVolumeEngineXPCProtocol.self)
    }

    /// Safely reads bounded non-symlink regular file JSON snapshot for CLI diagnostics & cold-start cache.
    static func readCachedSnapshot(from notification: Notification? = nil) -> VolumeState? {
        if let data = notification?.userInfo?["payload"] as? Data,
           data.count <= maxStateFileBytes,
           let state = decodeValidatedState(data) {
            return state
        }
        guard let data = readBoundedRegularFile(at: stateFile, maxBytes: maxStateFileBytes),
              let state = decodeValidatedState(data) else {
            return nil
        }
        return state
    }

    static func decodeValidatedState(_ data: Data) -> VolumeState? {
        guard data.count <= maxStateFileBytes,
              let state = try? JSONDecoder().decode(VolumeState.self, from: data),
              state.protocolVersion == VolumeState.currentProtocolVersion,
              state.enginePID > 0,
              (0...100).contains(state.volume),
              (1...100).contains(state.volumeLimit),
              !state.engineInstanceID.isEmpty,
              kill(state.enginePID, 0) == 0 else {
            return nil
        }
        return state
    }

    static func readBoundedRegularFile(at url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_size > 0,
              st.st_size <= off_t(maxBytes) else {
            return nil
        }
        var data = Data(count: Int(st.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.read(fd, base, Int(st.st_size))
        }
        guard bytesRead == Int(st.st_size) else { return nil }
        return data
    }

    static func publish(_ state: VolumeState, writeDisk: Bool = true, notify: Bool = true) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        if writeDisk {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: stateFile, options: .atomic)
                chmod(stateFile.path, 0o600)
            } catch {
                NSLog("DisplayVolume state disk write failed: %@", error.localizedDescription)
            }
        }
        if notify {
            DistributedNotificationCenter.default().postNotificationName(
                changed,
                object: nil,
                userInfo: ["payload": data],
                deliverImmediately: true
            )
        }
    }
}

/// In-process Security.framework bundle signature & Team ID inspector.
enum CodeSignInspector {
    struct SigningIdentity: Equatable, Sendable {
        let identifier: String
        let teamIdentifier: String?
        let isAdHoc: Bool
    }

    static func currentProcessIdentity() -> SigningIdentity? {
        inspectBundle(at: Bundle.main.bundleURL)
    }

    static func inspectBundle(at url: URL, verifyStrict: Bool = false) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return nil
        }
        if verifyStrict {
            let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
                return nil
            }
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flagsNum = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let isAdHoc = (flagsNum & SecCodeSignatureFlags.adhoc.rawValue) != 0
        return SigningIdentity(identifier: identifier, teamIdentifier: teamID, isAdHoc: isAdHoc)
    }

    /// Builds a strict XPC peer code-signing requirement string per Apple TN3127.
    static func peerCodeSigningRequirement(expectedBundleID: String, matchingOwnIdentity own: SigningIdentity?) -> String {
        if let team = own?.teamIdentifier, !team.isEmpty {
            return "anchor apple generic and identifier \"\(expectedBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        return "identifier \"\(expectedBundleID)\""
    }
}

/// Pure, overflow-safe volume state transitions kept free of CoreAudio/AppKit for direct unit testing.
enum VolumeMath {
    static func clampedVolume(_ value: Int, limit: Int) -> Int {
        let safeLimit = min(100, max(1, limit))
        return min(safeLimit, max(0, value))
    }

    static func applyStep(currentVolume: Int, limit: Int, muted: Bool, delta: Int) -> (volume: Int, muted: Bool) {
        let safeLimit = min(100, max(1, limit))
        let safeCurrent = min(safeLimit, max(0, currentVolume))
        // Clamp delta first so arbitrary Int.max / Int.min inputs can never overflow and trap.
        let safeDelta = min(100, max(-100, delta))

        if safeDelta > 0 {
            if muted {
                let target = safeCurrent > 0 ? safeCurrent : min(safeLimit, safeDelta)
                return (max(1, target), false)
            }
            let next = min(safeLimit, safeCurrent + safeDelta)
            return (max(1, next), false)
        } else if safeDelta < 0 {
            if muted {
                return (safeCurrent, true)
            }
            let next = safeCurrent + safeDelta
            if next <= 0 {
                return (max(1, safeCurrent), true)
            }
            return (next, false)
        }
        return (safeCurrent, muted)
    }
}

/// Pure soft-mute math for microphones without full-channel hardware kAudioDevicePropertyMute.
enum InputMuteMath {
    struct SoftMutePlan: Equatable, Sendable {
        let appliedPercent: Int
        let updatedSavedVolume: Int?
    }

    static func planSoftMute(currentPercent: Int, savedBeforeMute: Int?, targetMuted: Bool) -> SoftMutePlan {
        let clampedCurrent = min(100, max(0, currentPercent))
        if targetMuted {
            let save = clampedCurrent > 0 ? clampedCurrent : (savedBeforeMute ?? 50)
            return SoftMutePlan(appliedPercent: 0, updatedSavedVolume: max(1, min(100, save)))
        } else {
            let restore = clampedCurrent > 0 ? clampedCurrent : max(1, min(100, savedBeforeMute ?? 50))
            return SoftMutePlan(appliedPercent: restore, updatedSavedVolume: restore)
        }
    }
}

/// Pure throttling math shared across UI drag controls and HAL writers.
enum DispatchThrottleMath {
    static func shouldEmit(now: TimeInterval, lastSentAt: TimeInterval, minInterval: TimeInterval, isDragging: Bool) -> Bool {
        !isDragging || (now - lastSentAt) >= minInterval
    }
}
