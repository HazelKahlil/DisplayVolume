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

enum AudioTransportKind: String, Codable, Equatable, Sendable {
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

/// Unified channel control map for a device scope so read, write, and HAL listeners
/// always operate on the exact same set of active channel elements.
struct ChannelControlMap: Equatable, Hashable, Sendable {
    let volumeElements: [UInt32]
    let muteElements: [UInt32]
    let coversAllChannelsForVolume: Bool
    let coversAllChannelsForMute: Bool

    var hasWritableVolume: Bool { !volumeElements.isEmpty }
    var hasFullChannelVolume: Bool { !volumeElements.isEmpty && coversAllChannelsForVolume }
    var hasFullHardwareMute: Bool { !muteElements.isEmpty && coversAllChannelsForMute }
    var observedElements: [UInt32] {
        Array(Set(volumeElements + muteElements)).sorted()
    }

    static let empty = ChannelControlMap(
        volumeElements: [],
        muteElements: [],
        coversAllChannelsForVolume: false,
        coversAllChannelsForMute: false
    )

    /// Pure evaluator for multi-channel mute states: returns true ONLY when every mapped mute element is muted.
    static func aggregateMuteRead(_ values: [Bool?], expectedCount: Int) -> Bool? {
        guard expectedCount > 0, values.count == expectedCount else { return nil }
        var allMuted = true
        for v in values {
            guard let v else { return nil }
            if !v { allMuted = false }
        }
        return allMuted
    }
}

struct AudioDeviceInfo: Equatable, Hashable, Identifiable, Sendable {
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
    let outputControlMap: ChannelControlMap
    let inputControlMap: ChannelControlMap
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
        outputControlMap: ChannelControlMap = .empty,
        inputControlMap: ChannelControlMap = .empty,
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
        self.outputControlMap = outputControlMap
        self.inputControlMap = inputControlMap
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

    /// True if the input device supports verified full-channel hardware mute OR full-channel scalar attenuation.
    var inputMuteSupported: Bool {
        if inputMuteControlAvailable { return true }
        if inputControlMap.hasFullChannelVolume { return true }
        // Support constructed unit-test fixtures that didn't populate inputControlMap explicitly.
        return inputVolumeControlAvailable && inputControlMap == .empty
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
/// DisplayVolume itself never opens an audio capture stream for microphone control (no mic privacy dot from DisplayVolume).
enum AudioHardwareControl {
    static func probeControlMap(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        channelCount: Int
    ) -> ChannelControlMap {
        guard channelCount > 0 else { return .empty }
        let clampedCh = min(8, max(1, channelCount))

        let volumeElems = writableElements(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            channelCount: clampedCh
        )
        let muteElems = writableElements(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            channelCount: clampedCh
        )
        // Full-channel coverage requires either writable master element (0) or every active channel (1...N).
        let fullVolumeCoverage = volumeElems == [kAudioObjectPropertyElementMain] || volumeElems.count == clampedCh
        let fullMuteCoverage = muteElems == [kAudioObjectPropertyElementMain] || muteElems.count == clampedCh
        return ChannelControlMap(
            volumeElements: volumeElems,
            muteElements: muteElems,
            coversAllChannelsForVolume: fullVolumeCoverage,
            coversAllChannelsForMute: fullMuteCoverage
        )
    }

    private static func writableElements(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        channelCount: Int
    ) -> [UInt32] {
        var mainProp = audioAddress(selector, scope: scope, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &mainProp) {
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &mainProp, &writable) == noErr && writable.boolValue {
                return [kAudioObjectPropertyElementMain]
            }
        }
        var perChannel: [UInt32] = []
        for ch in 1...UInt32(channelCount) {
            var prop = audioAddress(selector, scope: scope, element: ch)
            guard AudioObjectHasProperty(deviceID, &prop) else { continue }
            var writable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &prop, &writable) == noErr && writable.boolValue {
                perChannel.append(ch)
            }
        }
        return perChannel
    }

    static func readScalarVolume(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        elements: [UInt32]
    ) -> Float? {
        guard !elements.isEmpty else { return nil }
        var values: [Float] = []
        values.reserveCapacity(elements.count)
        for elem in elements {
            var prop = audioAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: elem)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &size, &value) == noErr else {
                return nil
            }
            values.append(min(1, max(0, value)))
        }
        return values.reduce(0, +) / Float(values.count)
    }

    static func readScalarVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int) -> Float? {
        let map = probeControlMap(deviceID: deviceID, scope: scope, channelCount: channelCount)
        return readScalarVolume(deviceID: deviceID, scope: scope, elements: map.volumeElements)
    }

    @discardableResult
    static func writeScalarVolume(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        elements: [UInt32],
        fraction: Float
    ) -> Bool {
        guard !elements.isEmpty else { return false }
        var value = Float32(min(1, max(0, fraction)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var allOK = true
        for elem in elements {
            var prop = audioAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: elem)
            if AudioObjectSetPropertyData(deviceID, &prop, 0, nil, size, &value) != noErr {
                allOK = false
            }
        }
        return allOK
    }

    @discardableResult
    static func writeScalarVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int, fraction: Float) -> Bool {
        let map = probeControlMap(deviceID: deviceID, scope: scope, channelCount: channelCount)
        return writeScalarVolume(deviceID: deviceID, scope: scope, elements: map.volumeElements, fraction: fraction)
    }

    /// Reads mute state across all mapped elements. Returns true ONLY if EVERY mapped channel is muted.
    /// Returns nil if any channel read fails so callers never fabricate an "unmuted" or "muted" claim.
    static func readMute(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        elements: [UInt32]
    ) -> Bool? {
        guard !elements.isEmpty else { return nil }
        var reads: [Bool?] = []
        reads.reserveCapacity(elements.count)
        for elem in elements {
            var prop = audioAddress(kAudioDevicePropertyMute, scope: scope, element: elem)
            var raw: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &size, &raw) == noErr {
                reads.append(raw != 0)
            } else {
                reads.append(nil)
            }
        }
        return ChannelControlMap.aggregateMuteRead(reads, expectedCount: elements.count)
    }

    static func readMute(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int) -> Bool? {
        let map = probeControlMap(deviceID: deviceID, scope: scope, channelCount: channelCount)
        guard map.hasFullHardwareMute else { return nil }
        return readMute(deviceID: deviceID, scope: scope, elements: map.muteElements)
    }

    /// Writes mute across EVERY mapped channel and returns true ONLY when all channels succeed.
    @discardableResult
    static func writeMute(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        elements: [UInt32],
        muted: Bool
    ) -> Bool {
        guard !elements.isEmpty else { return false }
        var raw: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var allOK = true
        for elem in elements {
            var prop = audioAddress(kAudioDevicePropertyMute, scope: scope, element: elem)
            if AudioObjectSetPropertyData(deviceID, &prop, 0, nil, size, &raw) != noErr {
                allOK = false
            }
        }
        return allOK
    }

    @discardableResult
    static func writeMute(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, channelCount: Int, muted: Bool) -> Bool {
        let map = probeControlMap(deviceID: deviceID, scope: scope, channelCount: channelCount)
        guard map.hasFullHardwareMute else { return false }
        return writeMute(deviceID: deviceID, scope: scope, elements: map.muteElements, muted: muted)
    }
}

/// Single-pass CoreAudio device snapshot to eliminate redundant multi-scan HAL stalls on popover open & topology bursts.
struct AudioDeviceSnapshot: Equatable, Sendable {
    let outputDevices: [AudioDeviceInfo]
    let inputDevices: [AudioDeviceInfo]
    let defaultOutput: AudioDeviceInfo?
    let defaultInput: AudioDeviceInfo?
    let querySucceeded: Bool
}

enum AudioDeviceCatalog {
    static func captureSnapshot() -> AudioDeviceSnapshot {
        guard let all = OutputDeviceCatalog.fetchAllDevicesWithStatus() else {
            return AudioDeviceSnapshot(
                outputDevices: [],
                inputDevices: [],
                defaultOutput: OutputDeviceCatalog.currentDefault(),
                defaultInput: InputDeviceCatalog.currentDefault(),
                querySucceeded: false
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        let outputs = OutputDeviceCatalog.sortOutputs(all.filter { $0.outputChannels > 0 && !$0.isHidden })
        let inputs = InputDeviceCatalog.sortInputs(all.filter { $0.inputChannels > 0 && !$0.isHidden })

        let defaultOutID = readDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInID = readDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)

        let defaultOut = (defaultOutID.flatMap { byID[$0] } ?? defaultOutID.flatMap { OutputDeviceCatalog.inspect(deviceID: $0) })
            .flatMap { $0.outputChannels > 0 ? $0 : nil }
        let defaultIn = (defaultInID.flatMap { byID[$0] } ?? defaultInID.flatMap { OutputDeviceCatalog.inspect(deviceID: $0) })
            .flatMap { $0.inputChannels > 0 ? $0 : nil }

        return AudioDeviceSnapshot(
            outputDevices: outputs,
            inputDevices: inputs,
            defaultOutput: defaultOut,
            defaultInput: defaultIn,
            querySucceeded: true
        )
    }

    static func readDefaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var property = audioAddress(selector)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }
}

enum OutputDeviceCatalog {
    static func currentDefault() -> AudioDeviceInfo? {
        guard let id = AudioDeviceCatalog.readDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice),
              let info = inspect(deviceID: id),
              info.outputChannels > 0 else {
            return nil
        }
        return info
    }

    static func sortOutputs(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        devices.sorted { lhs, rhs in
            if lhs.isPhysicalOutput != rhs.isPhysicalOutput { return lhs.isPhysicalOutput }
            if lhs.isAutoControllable != rhs.isAutoControllable { return lhs.isAutoControllable }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func allOutputDevices() -> [AudioDeviceInfo] {
        sortOutputs(allDevices().filter { $0.outputChannels > 0 && !$0.isHidden })
    }

    /// Switches playback output only (does NOT silently alter system alert sound routing).
    @discardableResult
    static func setDefaultOutput(deviceID: AudioDeviceID, expectedUID: String? = nil) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        if let expectedUID, readString(deviceID, kAudioDevicePropertyDeviceUID) != expectedUID {
            return setDefaultOutput(uid: expectedUID)
        }
        var id = deviceID
        let size = UInt32(MemoryLayout.size(ofValue: id))
        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, size, &id) == noErr
    }

    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard let target = allOutputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultOutput(deviceID: target.id, expectedUID: nil)
    }

    static func allDevices() -> [AudioDeviceInfo] {
        fetchAllDevicesWithStatus() ?? []
    }

    /// Bounded retry query that trims strictly to the byte count returned by HAL (handles hotplug race cleanly).
    static func fetchAllDevicesWithStatus() -> [AudioDeviceInfo]? {
        var property = audioAddress(kAudioHardwarePropertyDevices)
        let stride = MemoryLayout<AudioDeviceID>.stride
        for _ in 0..<2 {
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else {
                return nil
            }
            if size == 0 { return [] }
            let capacity = Int(size) / stride
            guard capacity > 0 else { return [] }
            var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: capacity)
            var actualSize = size
            let status = ids.withUnsafeMutableBytes { buf in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &actualSize, buf.baseAddress!)
            }
            if status == noErr {
                let actualCount = min(capacity, Int(actualSize) / stride)
                return ids.prefix(actualCount).compactMap { $0 != kAudioObjectUnknown ? inspect(deviceID: $0) : nil }
            }
        }
        return nil
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

        let outMap = outChannels > 0
            ? AudioHardwareControl.probeControlMap(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput, channelCount: outChannels)
            : .empty
        let inMap = inChannels > 0
            ? AudioHardwareControl.probeControlMap(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput, channelCount: inChannels)
            : .empty

        return AudioDeviceInfo(
            id: deviceID,
            name: name,
            uid: uid,
            transport: transport,
            outputChannels: outChannels,
            inputChannels: inChannels,
            volumeControlAvailable: outMap.hasWritableVolume,
            muteControlAvailable: outMap.hasFullHardwareMute,
            inputVolumeControlAvailable: inMap.hasWritableVolume,
            inputMuteControlAvailable: inMap.hasFullHardwareMute,
            outputControlMap: outMap,
            inputControlMap: inMap,
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
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<UInt32>.size) else {
            return 0
        }
        let allocBytes = Int(size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: allocBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var actualSize = size
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &actualSize, raw) == noErr,
              actualSize >= UInt32(MemoryLayout<UInt32>.size) else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let declaredBuffers = Int(list.pointee.mNumberBuffers)
        let headerOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? MemoryLayout<UInt32>.size
        let requiredBytes = headerOffset + declaredBuffers * MemoryLayout<AudioBuffer>.stride
        guard declaredBuffers >= 0, requiredBytes <= Int(actualSize), requiredBytes <= allocBytes else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = audioAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

enum InputDeviceCatalog {
    static func currentDefault() -> AudioDeviceInfo? {
        guard let id = AudioDeviceCatalog.readDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice),
              let info = OutputDeviceCatalog.inspect(deviceID: id),
              info.inputChannels > 0 else {
            return nil
        }
        return info
    }

    static func sortInputs(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        devices.sorted { lhs, rhs in
            if lhs.isPhysicalInput != rhs.isPhysicalInput { return lhs.isPhysicalInput }
            let lhsExternal = lhs.transportKind == .usb || lhs.transportKind == .bluetooth
            let rhsExternal = rhs.transportKind == .usb || rhs.transportKind == .bluetooth
            if lhsExternal != rhsExternal { return lhsExternal }
            if lhs.transportKind == .builtIn && rhs.transportKind != .builtIn { return true }
            if rhs.transportKind == .builtIn && lhs.transportKind != .builtIn { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func allInputDevices() -> [AudioDeviceInfo] {
        sortInputs(OutputDeviceCatalog.allDevices().filter { $0.inputChannels > 0 && !$0.isHidden })
    }

    @discardableResult
    static func setDefaultInput(deviceID: AudioDeviceID, expectedUID: String? = nil) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        if let expectedUID, OutputDeviceCatalog.readString(deviceID, kAudioDevicePropertyDeviceUID) != expectedUID {
            return setDefaultInput(uid: expectedUID)
        }
        var id = deviceID
        let size = UInt32(MemoryLayout.size(ofValue: id))
        var inAddr = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &inAddr, 0, nil, size, &id) == noErr
    }

    @discardableResult
    static func setDefaultInput(uid: String) -> Bool {
        guard let target = allInputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultInput(deviceID: target.id, expectedUID: nil)
    }
}

/// Shared hardware + soft-gain microphone controller.
/// Mutations are serialized inside DisplayVolumeEngine to prevent dual-process races on HAL mute/gain & UserDefaults.
enum MicrophoneControl {
    private static let savedVolumeKey = "SavedMicVolumeBeforeSoftMute"

    struct Status: Equatable, Codable, Sendable {
        let volumePercent: Int
        let muted: Bool
        let volumeWritable: Bool
        let muteSupported: Bool
        let usesSoftMute: Bool
        let readSucceeded: Bool
    }

    static func readStatus(for device: AudioDeviceInfo) -> Status {
        let map = device.inputControlMap.hasWritableVolume || device.inputControlMap.hasFullHardwareMute
            ? device.inputControlMap
            : AudioHardwareControl.probeControlMap(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                channelCount: device.inputChannels
            )

        let rawScalar = map.hasWritableVolume
            ? AudioHardwareControl.readScalarVolume(deviceID: device.id, scope: kAudioDevicePropertyScopeInput, elements: map.volumeElements)
            : nil
        let currentPct = rawScalar.map { Int(($0 * 100.0).rounded()) } ?? 0

        if map.hasFullHardwareMute {
            guard let hwMuted = AudioHardwareControl.readMute(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                elements: map.muteElements
            ) else {
                return Status(
                    volumePercent: currentPct,
                    muted: false,
                    volumeWritable: map.hasWritableVolume,
                    muteSupported: true,
                    usesSoftMute: false,
                    readSucceeded: false
                )
            }
            return Status(
                volumePercent: currentPct,
                muted: hwMuted,
                volumeWritable: map.hasWritableVolume,
                muteSupported: true,
                usesSoftMute: false,
                readSucceeded: rawScalar != nil || !map.hasWritableVolume
            )
        }

        if map.hasFullChannelVolume {
            guard let rawScalar else {
                return Status(
                    volumePercent: 0,
                    muted: false,
                    volumeWritable: true,
                    muteSupported: true,
                    usesSoftMute: true,
                    readSucceeded: false
                )
            }
            // Exact scalar near-zero check across ALL active channels (never claims muted if any channel lacks gain control).
            let isSoftZero = rawScalar <= 0.001
            let displayPct = isSoftZero ? (savedPreMuteVolume(uid: device.uid) ?? 50) : currentPct
            return Status(
                volumePercent: displayPct,
                muted: isSoftZero,
                volumeWritable: true,
                muteSupported: true,
                usesSoftMute: true,
                readSucceeded: true
            )
        }

        if map.hasWritableVolume {
            // Partial-channel gain control: allow gain slider, but NEVER report muteSupported or muted.
            return Status(
                volumePercent: currentPct,
                muted: false,
                volumeWritable: true,
                muteSupported: false,
                usesSoftMute: false,
                readSucceeded: rawScalar != nil
            )
        }

        return Status(
            volumePercent: 0,
            muted: false,
            volumeWritable: false,
            muteSupported: false,
            usesSoftMute: false,
            readSucceeded: true
        )
    }

    /// Writes microphone gain to CoreAudio HAL without clearing an explicit hardware mute unless `clearMuteIfPositive` is true.
    @discardableResult
    static func applyVolume(
        _ percent: Int,
        for device: AudioDeviceInfo,
        persistPreMute: Bool = true,
        clearMuteIfPositive: Bool = false
    ) -> Bool {
        let clamped = min(100, max(0, percent))
        let map = device.inputControlMap.hasWritableVolume
            ? device.inputControlMap
            : AudioHardwareControl.probeControlMap(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                channelCount: device.inputChannels
            )
        guard map.hasWritableVolume else { return false }

        let ok = AudioHardwareControl.writeScalarVolume(
            deviceID: device.id,
            scope: kAudioDevicePropertyScopeInput,
            elements: map.volumeElements,
            fraction: Float(clamped) / 100.0
        )
        if ok && clamped > 0 {
            if persistPreMute {
                savePreMuteVolume(clamped, uid: device.uid)
            }
            if clearMuteIfPositive && map.hasFullHardwareMute {
                _ = AudioHardwareControl.writeMute(
                    deviceID: device.id,
                    scope: kAudioDevicePropertyScopeInput,
                    elements: map.muteElements,
                    muted: false
                )
            }
        }
        return ok
    }

    @discardableResult
    static func setVolume(_ percent: Int, for device: AudioDeviceInfo) -> Status {
        _ = applyVolume(percent, for: device, persistPreMute: true, clearMuteIfPositive: false)
        return readStatus(for: device)
    }

    @discardableResult
    static func toggleMute(for device: AudioDeviceInfo) -> Status? {
        guard device.inputMuteSupported else { return nil }
        let current = readStatus(for: device)
        guard current.readSucceeded else { return nil }
        return setMuted(!current.muted, for: device)
    }

    @discardableResult
    static func setMuted(_ muted: Bool, for device: AudioDeviceInfo) -> Status? {
        guard device.inputMuteSupported else { return nil }
        let map = device.inputControlMap.hasWritableVolume || device.inputControlMap.hasFullHardwareMute
            ? device.inputControlMap
            : AudioHardwareControl.probeControlMap(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                channelCount: device.inputChannels
            )

        if map.hasFullHardwareMute {
            let wroteAll = AudioHardwareControl.writeMute(
                deviceID: device.id,
                scope: kAudioDevicePropertyScopeInput,
                elements: map.muteElements,
                muted: muted
            )
            let verified = readStatus(for: device)
            return wroteAll && verified.readSucceeded ? verified : nil
        }

        // Soft-gain attenuation fallback ONLY when writable scalar gain covers ALL active input channels.
        guard map.hasFullChannelVolume,
              let currentScalar = AudioHardwareControl.readScalarVolume(
                  deviceID: device.id,
                  scope: kAudioDevicePropertyScopeInput,
                  elements: map.volumeElements
              ) else {
            return nil
        }
        let currentPct = Int((currentScalar * 100.0).rounded())
        let plan = InputMuteMath.planSoftMute(
            currentPercent: currentPct,
            savedBeforeMute: savedPreMuteVolume(uid: device.uid),
            targetMuted: muted
        )
        if let toSave = plan.updatedSavedVolume {
            savePreMuteVolume(toSave, uid: device.uid)
        }
        let wroteAll = AudioHardwareControl.writeScalarVolume(
            deviceID: device.id,
            scope: kAudioDevicePropertyScopeInput,
            elements: map.volumeElements,
            fraction: Float(plan.appliedPercent) / 100.0
        )
        let verified = readStatus(for: device)
        return wroteAll && verified.readSucceeded ? verified : nil
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
