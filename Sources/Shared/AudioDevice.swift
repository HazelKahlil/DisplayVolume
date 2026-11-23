import CoreAudio
import Foundation

struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) (\(status))"
    }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure(operation: operation, status: status) }
}

func audioAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

enum AudioTransportKind: String, Codable, Equatable {
    case displayPort
    case hdmi
    case thunderbolt
    case usb
    case builtIn
    case bluetooth
    case airPlay
    case virtual
    case aggregate
    case other

    init(coreAudioTransport: UInt32) {
        switch coreAudioTransport {
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }

    var displayLabel: String {
        switch self {
        case .displayPort: return "DisplayPort"
        case .hdmi: return "HDMI"
        case .thunderbolt: return "Thunderbolt"
        case .usb: return "USB"
        case .builtIn: return L10n.text("内建", "Built-in")
        case .bluetooth: return L10n.text("蓝牙", "Bluetooth")
        case .airPlay: return "AirPlay"
        case .virtual: return L10n.text("虚拟设备", "Virtual")
        case .aggregate: return L10n.text("聚合设备", "Aggregate")
        case .other: return L10n.text("外接输出", "External")
        }
    }

    var isExternalDisplayOrDigital: Bool {
        switch self {
        case .displayPort, .hdmi, .thunderbolt: return true
        default: return false
        }
    }

    var isVirtualOrAggregate: Bool {
        self == .virtual || self == .aggregate
    }
}

struct AudioDeviceInfo: Equatable, Hashable, Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: UInt32
    let outputChannels: Int
    let volumeControlAvailable: Bool
    let isHidden: Bool

    var transportKind: AudioTransportKind {
        AudioTransportKind(coreAudioTransport: transport)
    }

    /// Physical outputs that lack macOS native volume control (DisplayPort/HDMI/Thunderbolt/SPDIF/locked USB).
    var isAutoControllable: Bool {
        !isHidden && !transportKind.isVirtualOrAggregate && outputChannels > 0 && !volumeControlAvailable
    }

    var isPhysicalOutput: Bool {
        !isHidden && !transportKind.isVirtualOrAggregate && outputChannels > 0
    }

    var symbolName: String {
        switch transportKind {
        case .displayPort, .hdmi, .thunderbolt: return "display"
        case .bluetooth: return "airpodspro"
        case .builtIn: return "macbook"
        case .usb: return "hifispeaker.fill"
        case .airPlay: return "airplayaudio"
        case .virtual, .aggregate, .other: return "speaker.wave.2"
        }
    }

    var isAlive: Bool {
        var property = audioAddress(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: alive))
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &alive) == noErr && alive != 0
    }

    var isRunningSomewhere: Bool {
        var property = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: running))
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &running) == noErr && running != 0
    }
}

enum OutputDeviceCatalog {
    static func currentDefault() -> AudioDeviceInfo? {
        var property = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else {
            return nil
        }
        return inspect(deviceID: id)
    }

    static func allOutputDevices() -> [AudioDeviceInfo] {
        var property = audioAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes { buf in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { inspect(deviceID: $0) }
            .filter { $0.outputChannels > 0 && !$0.isHidden }
            .sorted { lhs, rhs in
                if lhs.isPhysicalOutput != rhs.isPhysicalOutput { return lhs.isPhysicalOutput }
                if lhs.isAutoControllable != rhs.isAutoControllable { return lhs.isAutoControllable }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard let target = allOutputDevices().first(where: { $0.uid == uid }) else { return false }
        var id = target.id
        let size = UInt32(MemoryLayout.size(ofValue: id))
        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let outStatus = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, size, &id)
        var sysAddr = audioAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sysAddr, 0, nil, size, &id)
        return outStatus == noErr
    }

    static func inspect(deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = readString(deviceID, kAudioObjectPropertyName),
              let uid = readString(deviceID, kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        var transportProp = audioAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: transport))
        guard AudioObjectGetPropertyData(deviceID, &transportProp, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        let channels = outputChannelCount(deviceID)
        guard channels > 0 else { return nil }
        return AudioDeviceInfo(
            id: deviceID,
            name: name,
            uid: uid,
            transport: transport,
            outputChannels: channels,
            volumeControlAvailable: hasWritableScalarVolume(deviceID),
            isHidden: isHiddenDevice(deviceID)
        )
    }

    private static func isHiddenDevice(_ id: AudioDeviceID) -> Bool {
        var prop = audioAddress(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: hidden))
        return AudioObjectGetPropertyData(id, &prop, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func hasWritableScalarVolume(_ id: AudioDeviceID) -> Bool {
        for element in [UInt32(0), 1, 2] {
            var property = audioAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &property, &writable) == noErr && writable.boolValue {
                return true
            }
        }
        return false
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var property = audioAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = audioAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
