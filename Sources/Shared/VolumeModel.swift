import Foundation

struct DeviceVolumeProfile: Codable, Equatable {
    var volume: Int
    var volumeLimit: Int
    var muted: Bool
    var enabled: Bool

    static let defaultSafe = DeviceVolumeProfile(volume: 50, volumeLimit: 100, muted: false, enabled: true)
}

struct VolumeState: Codable, Equatable {
    enum Phase: String, Codable {
        case idle
        case checking
        case active
    }

    enum TriggerSource: String, Codable {
        case mediaKey
        case hotkey
        case scroll
        case slider
        case preset
        case system
    }

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

enum VolumeCommand: String {
    case enable
    case pause
    case volume
    case step
    case limit
    case mute
    case requestAccessibility
    case setShowOSD
    case setShowMenuBarPercent
    case setScrollOnIcon
    case setUIMediaKeysActive
    case toggleMicMute
    case showMicOSD
    case reverifyCapture
    case shutdownEngine
}

enum VolumeIPC {
    static let suiteName = "com.hazelkahlil.DisplayVolume"
    static let legacySuiteName = "local.kahlil.RedmiVolume"
    static let engineBundleID = "com.hazelkahlil.DisplayVolume.Engine"
    static let legacyEngineBundleID = "local.kahlil.RedmiVolume.Engine"

    static let command = Notification.Name("com.hazelkahlil.DisplayVolume.engine-command")
    static let changed = Notification.Name("com.hazelkahlil.DisplayVolume.engine-state")

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DisplayVolume", isDirectory: true)
    static let stateFile = directory.appendingPathComponent("state.json")

    static func read(from notification: Notification? = nil) -> VolumeState? {
        if let data = notification?.userInfo?["payload"] as? Data,
           let state = try? JSONDecoder().decode(VolumeState.self, from: data),
           state.enginePID > 0,
           kill(state.enginePID, 0) == 0 {
            return state
        }
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(VolumeState.self, from: data),
              state.enginePID > 0,
              kill(state.enginePID, 0) == 0 else {
            return nil
        }
        return state
    }

    static func send(_ kind: VolumeCommand, value: Int? = nil, flag: Bool? = nil, source: VolumeState.TriggerSource? = nil) {
        var info: [String: Any] = ["action": kind.rawValue]
        if let value { info["value"] = value }
        if let flag { info["flag"] = flag }
        if let source { info["source"] = source.rawValue }
        DistributedNotificationCenter.default().postNotificationName(
            command,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }

    static func publish(_ state: VolumeState, writeDisk: Bool = true, notify: Bool = true) {
        do {
            let data = try JSONEncoder().encode(state)
            if writeDisk {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: stateFile, options: .atomic)
            }
            if notify {
                DistributedNotificationCenter.default().postNotificationName(
                    changed,
                    object: nil,
                    userInfo: ["payload": data],
                    deliverImmediately: true
                )
            }
        } catch {
            NSLog("DisplayVolume state publish failed: %@", error.localizedDescription)
        }
    }
}

/// Pure volume state transitions, kept free of CoreAudio/AppKit for direct unit testing.
enum VolumeMath {
    static func clampedVolume(_ value: Int, limit: Int) -> Int {
        let safeLimit = min(100, max(1, limit))
        return min(safeLimit, max(0, value))
    }

    static func applyStep(currentVolume: Int, limit: Int, muted: Bool, delta: Int) -> (volume: Int, muted: Bool) {
        let safeLimit = min(100, max(1, limit))
        if delta > 0 {
            if muted {
                let target = currentVolume > 0 ? min(safeLimit, currentVolume) : min(safeLimit, delta)
                return (max(1, target), false)
            }
            let next = min(safeLimit, currentVolume + delta)
            return (max(1, next), false)
        } else if delta < 0 {
            if muted {
                return (currentVolume, true)
            }
            let next = currentVolume + delta
            if next <= 0 {
                // Keep stored volume small so unmuting later recovers softly at the last audible level.
                return (max(1, min(safeLimit, currentVolume)), true)
            }
            return (next, false)
        }
        return (min(safeLimit, currentVolume), muted)
    }
}

/// Pure soft-mute math for microphones without hardware kAudioDevicePropertyMute.
enum InputMuteMath {
    struct SoftMutePlan: Equatable {
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
