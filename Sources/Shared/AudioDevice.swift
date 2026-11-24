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
    case continuity
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
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .continuity
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
        case .continuity: return L10n.text("连续互通", "Continuity")
        case .virtual: return L10n.text("虚拟设备", "Virtual")
        case .aggregate: return L10n.text("聚合设备", "Aggregate")
        case .other: return L10n.text("外接设备", "External")
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
    let inputChannels: Int
    let volumeControlAvailable: Bool
    let muteControlAvailable: Bool
    let inputVolumeControlAvailable: Bool
    let inputMuteControlAvailable: Bool
    let isHidden: Bool

    init(
        id: AudioDeviceID,
        name: String,
        uid: String,
        transport: UInt32,
        outputChannels: Int,
        inputChannels: Int = 0,
        volumeControlAvailable: Bool,
        muteControlAvailable: Bool = false,
        inputVolumeControlAvailable: Bool = false,
        inputMuteControlAvailable: Bool = false,
        isHidden: Bool
    ) {
        self.id = id
        self.name = name
        self.uid = uid
        self.transport = transport
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.volumeControlAvailable = volumeControlAvailable
        self.muteControlAvailable = muteControlAvailable
        self.inputVolumeControlAvailable = inputVolumeControlAvailable
        self.inputMuteControlAvailable = inputMuteControlAvailable
        self.isHidden = isHidden
    }

    var transportKind: AudioTransportKind {
        AudioTransportKind(coreAudioTransport: transport)
    }

    /// Physical outputs that lack macOS native volume control (DisplayPort/HDMI/Thunderbolt/locked USB).
    var isAutoControllable: Bool {
        !isHidden && !transportKind.isVirtualOrAggregate && outputChannels > 0 && !volumeControlAvailable
    }

    var isPhysicalOutput: Bool {
        !isHidden && !transportKind.isVirtualOrAggregate && outputChannels > 0
    }

    var isPhysicalInput: Bool {
        !isHidden && !transportKind.isVirtualOrAggregate && inputChannels > 0
    }

    /// True if the input device supports either hardware mute or scalar gain attenuation to 0.
    var inputMuteSupported: Bool {
        inputMuteControlAvailable || inputVolumeControlAvailable
    }

    var symbolName: String {
        symbolName(forInput: false)
    }

    func symbolName(forInput: Bool) -> String {
        if forInput {
            switch transportKind {
            case .continuity: return "iphone"
            case .bluetooth: return "airpodspro"
            case .builtIn: return "macbook"
            case .virtual, .aggregate: return "waveform"
            default: return "mic.fill"
            }
        }
        switch transportKind {
        case .displayPort, .hdmi, .thunderbolt: return "display"
        case .bluetooth: return "airpodspro"
        case .builtIn: return "macbook"
        case .usb: return "hifispeaker.fill"
        case .airPlay: return "airplayaudio"
        case .continuity: return "iphone"
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

/// Direct CoreAudio HAL property access for hardware output/input volume and mute.
/// Uses HAL property calls only — never opens an audio capture stream (no mic privacy dot, no AirPods HFP downgrade).
enum AudioHardwareControl {
    private static func candidateElements(channelCount: Int) -> [UInt32] {
        let maxCh = UInt32(min(8, max(2, channelCount)))
        return [0] + Array(1...maxCh)
    }

    static func hasWritableProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        channelCount: Int
    ) -> Bool {
        for element in candidateElements(channelCount: channelCount) {
            var property = audioAddress(selector, scope: scope, element: element)
            guard AudioObjectHasProperty(id, &property) else { continue }
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &property, &writable) == noErr && writable.boolValue {
                return true
            }
        }
        return false
    }

    static func readScalarVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int) -> Float? {
        var mainProp = audioAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &mainProp) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &mainProp, 0, nil, &size, &value) == noErr {
                return min(1, max(0, value))
            }
        }

        let maxCh = UInt32(min(8, max(2, channelCount)))
        var values: [Float] = []
        for ch in 1...maxCh {
            var prop = audioAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)
            guard AudioObjectHasProperty(deviceID, &prop) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &size, &value) == noErr {
                values.append(min(1, max(0, value)))
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    @discardableResult
    static func writeScalarVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int, fraction: Float) -> Bool {
        var value = Float32(min(1, max(0, fraction)))
        let size = UInt32(MemoryLayout<Float32>.size)

        var mainProp = audioAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &mainProp) {
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &mainProp, &writable) == noErr && writable.boolValue {
                return AudioObjectSetPropertyData(deviceID, &mainProp, 0, nil, size, &value) == noErr
            }
        }

        let maxCh = UInt32(min(8, max(2, channelCount)))
        var wroteAny = false
        for ch in 1...maxCh {
            var prop = audioAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)
            guard AudioObjectHasProperty(deviceID, &prop) else { continue }
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &prop, &writable) == noErr && writable.boolValue {
                if AudioObjectSetPropertyData(deviceID, &prop, 0, nil, size, &value) == noErr {
                    wroteAny = true
                }
            }
        }
        return wroteAny
    }

    static func readMute(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int) -> Bool? {
        for element in candidateElements(channelCount: channelCount) {
            var prop = audioAddress(kAudioDevicePropertyMute, scope: scope, element: element)
            guard AudioObjectHasProperty(deviceID, &prop) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return nil
    }

    @discardableResult
    static func writeMute(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int, muted: Bool) -> Bool {
        var raw: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)

        var mainProp = audioAddress(kAudioDevicePropertyMute, scope: scope, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &mainProp) {
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &mainProp, &writable) == noErr && writable.boolValue {
                return AudioObjectSetPropertyData(deviceID, &mainProp, 0, nil, size, &raw) == noErr
            }
        }

        let maxCh = UInt32(min(8, max(2, channelCount)))
        var wroteAny = false
        for ch in 1...maxCh {
            var prop = audioAddress(kAudioDevicePropertyMute, scope: scope, element: ch)
            guard AudioObjectHasProperty(deviceID, &prop) else { continue }
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &prop, &writable) == noErr && writable.boolValue {
                if AudioObjectSetPropertyData(deviceID, &prop, 0, nil, size, &raw) == noErr {
                    wroteAny = true
                }
            }
        }
        return wroteAny
    }
}

enum OutputDeviceCatalog {
    static func currentDefault() -> AudioDeviceInfo? {
        var property = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown,
              let info = inspect(deviceID: id),
              info.outputChannels > 0 else {
            return nil
        }
        return info
    }

    static func allOutputDevices() -> [AudioDeviceInfo] {
        allDevices()
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

    static func allDevices() -> [AudioDeviceInfo] {
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
        let outChannels = channelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)
        let inChannels = channelCount(deviceID, scope: kAudioDevicePropertyScopeInput)
        guard outChannels > 0 || inChannels > 0 else { return nil }

        let outVol = outChannels > 0 && AudioHardwareControl.hasWritableProperty(
            deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, channelCount: outChannels
        )
        let outMute = outChannels > 0 && AudioHardwareControl.hasWritableProperty(
            deviceID, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, channelCount: outChannels
        )
        let inVol = inChannels > 0 && AudioHardwareControl.hasWritableProperty(
            deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, channelCount: inChannels
        )
        let inMute = inChannels > 0 && AudioHardwareControl.hasWritableProperty(
            deviceID, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput, channelCount: inChannels
        )

        return AudioDeviceInfo(
            id: deviceID,
            name: name,
            uid: uid,
            transport: transport,
            outputChannels: outChannels,
            inputChannels: inChannels,
            volumeControlAvailable: outVol,
            muteControlAvailable: outMute,
            inputVolumeControlAvailable: inVol,
            inputMuteControlAvailable: inMute,
            isHidden: isHiddenDevice(deviceID)
        )
    }

    private static func isHiddenDevice(_ id: AudioDeviceID) -> Bool {
        var prop = audioAddress(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: hidden))
        return AudioObjectGetPropertyData(id, &prop, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var property = audioAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
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

enum InputDeviceCatalog {
    static func currentDefault() -> AudioDeviceInfo? {
        var property = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown,
              let info = OutputDeviceCatalog.inspect(deviceID: id),
              info.inputChannels > 0 else {
            return nil
        }
        return info
    }

    static func allInputDevices() -> [AudioDeviceInfo] {
        OutputDeviceCatalog.allDevices()
            .filter { $0.inputChannels > 0 && !$0.isHidden }
            .sorted { lhs, rhs in
                if lhs.isPhysicalInput != rhs.isPhysicalInput { return lhs.isPhysicalInput }
                let lhsExternal = lhs.transportKind == .usb || lhs.transportKind == .bluetooth
                let rhsExternal = rhs.transportKind == .usb || rhs.transportKind == .bluetooth
                if lhsExternal != rhsExternal { return lhsExternal }
                if lhs.transportKind == .builtIn && rhs.transportKind != .builtIn { return true }
                if rhs.transportKind == .builtIn && lhs.transportKind != .builtIn { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @discardableResult
    static func setDefaultInput(uid: String) -> Bool {
        guard let target = allInputDevices().first(where: { $0.uid == uid }) else { return false }
        var id = target.id
        let size = UInt32(MemoryLayout.size(ofValue: id))
        var inAddr = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &inAddr, 0, nil, size, &id) == noErr
    }
}

/// Shared hardware + soft-gain microphone mute helper so both UI and background Engine stay consistent.
enum MicrophoneControl {
    private static let savedVolumeKey = "SavedMicVolumeBeforeSoftMute"

    struct Status: Equatable {
        let volumePercent: Int
        let muted: Bool
        let volumeWritable: Bool
        let muteSupported: Bool
        let usesSoftMute: Bool
    }

    static func readStatus(for device: AudioDeviceInfo) -> Status {
        let rawScalar = AudioHardwareControl.readScalarVolume(
            deviceID: device.id,
            scope: kAudioDevicePropertyScopeInput,
            channelCount: device.inputChannels
        )
        let currentPct = Int(((rawScalar ?? 0.5) * 100.0).rounded())

        if device.inputMuteControlAvailable {
            let hwMuted = AudioHardwareControl.readMute(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                channelCount: device.inputChannels
            ) ?? false
            return Status(
                volumePercent: currentPct,
                muted: hwMuted,
                volumeWritable: device.inputVolumeControlAvailable,
                muteSupported: true,
                usesSoftMute: false
            )
        }

        if device.inputVolumeControlAvailable {
            let isSoftMuted = currentPct == 0
            let displayPct = isSoftMuted ? (savedPreMuteVolume(uid: device.uid) ?? 50) : currentPct
            return Status(
                volumePercent: displayPct,
                muted: isSoftMuted,
                volumeWritable: true,
                muteSupported: true,
                usesSoftMute: true
            )
        }

        return Status(
            volumePercent: currentPct,
            muted: false,
            volumeWritable: false,
            muteSupported: false,
            usesSoftMute: false
        )
    }

    @discardableResult
    static func setVolume(_ percent: Int, for device: AudioDeviceInfo) -> Status {
        let clamped = min(100, max(0, percent))
        if device.inputVolumeControlAvailable {
            _ = AudioHardwareControl.writeScalarVolume(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                channelCount: device.inputChannels,
                fraction: Float(clamped) / 100.0
            )
            if clamped > 0 {
                savePreMuteVolume(clamped, uid: device.uid)
                if device.inputMuteControlAvailable {
                    _ = AudioHardwareControl.writeMute(
                        deviceID: device.id,
                        scope: kAudioDevicePropertyScopeInput,
                        channelCount: device.inputChannels,
                        muted: false
                    )
                }
            }
        }
        return readStatus(for: device)
    }

    @discardableResult
    static func toggleMute(for device: AudioDeviceInfo) -> Status? {
        guard device.inputMuteSupported else { return nil }
        let current = readStatus(for: device)
        let targetMuted = !current.muted
        return setMuted(targetMuted, for: device)
    }

    @discardableResult
    static func setMuted(_ muted: Bool, for device: AudioDeviceInfo) -> Status? {
        guard device.inputMuteSupported else { return nil }
        if device.inputMuteControlAvailable {
            _ = AudioHardwareControl.writeMute(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                channelCount: device.inputChannels,
                muted: muted
            )
            return readStatus(for: device)
        }

        // Soft-gain mute fallback for USB mics without hardware kAudioDevicePropertyMute.
        let currentScalar = AudioHardwareControl.readScalarVolume(
            deviceID: device.id,
            scope: kAudioDevicePropertyScopeInput,
            channelCount: device.inputChannels
        )
        let currentPct = Int(((currentScalar ?? 0.5) * 100.0).rounded())
        let plan = InputMuteMath.planSoftMute(
            currentPercent: currentPct,
            savedBeforeMute: savedPreMuteVolume(uid: device.uid),
            targetMuted: muted
        )
        if let toSave = plan.updatedSavedVolume {
            savePreMuteVolume(toSave, uid: device.uid)
        }
        _ = AudioHardwareControl.writeScalarVolume(
            deviceID: device.id,
            scope: kAudioDevicePropertyScopeInput,
            channelCount: device.inputChannels,
            fraction: Float(plan.appliedPercent) / 100.0
        )
        return readStatus(for: device)
    }

    private static func savedPreMuteVolume(uid: String) -> Int? {
        let prefs = UserDefaults(suiteName: VolumeIPC.suiteName)
        let dict = prefs?.dictionary(forKey: savedVolumeKey) as? [String: Int]
        return dict?[uid]
    }

    private static func savePreMuteVolume(_ percent: Int, uid: String) {
        let clamped = min(100, max(1, percent))
        let prefs = UserDefaults(suiteName: VolumeIPC.suiteName)
        var dict = (prefs?.dictionary(forKey: savedVolumeKey) as? [String: Int]) ?? [:]
        dict[uid] = clamped
        prefs?.set(dict, forKey: savedVolumeKey)
    }
}
