import CoreAudio
import Foundation

final class AudioRoute {
    let device: AudioDeviceInfo
    var onStreamFormatChanged: (() -> Void)?

    private var tap: AudioObjectID = kAudioObjectUnknown
    private var aggregate: AudioDeviceID = kAudioObjectUnknown
    private var outputStreamID: AudioStreamID = kAudioObjectUnknown
    private var formatListenerBlock: AudioObjectPropertyListenerBlock?
    private var callback: AudioDeviceIOProcID?
    private var gain: OpaquePointer?
    private var tapDescription: CATapDescription?
    private var started = false

    init(device: AudioDeviceInfo) {
        self.device = device
    }

    deinit { stop() }

    /// Starts the CoreAudio process tap. If `immediateVolume` is supplied (permission already verified),
    /// attenuation engages synchronously before audio starts so the first millisecond never blasts at 100%.
    func start(immediateVolume: Double? = nil) throws {
        guard OutputDeviceCatalog.currentDefault()?.uid == device.uid,
              device.isAlive else {
            throw AudioFailure(operation: L10n.text("连接音频输出设备", "Connect output device"), status: kAudioHardwareBadDeviceError)
        }
        do {
            let ownProcess = try Self.audioProcessID()
            let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: device.uid, stream: 0)
            description.name = "DisplayVolume"
            description.isPrivate = true
            description.muteBehavior = immediateVolume != nil ? .mutedWhenTapped : .unmuted
            try checkAudio(AudioHardwareCreateProcessTap(description, &tap), L10n.text("创建系统音频流", "Create audio tap"))
            tapDescription = description

            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "DisplayVolume",
                kAudioAggregateDeviceUIDKey: "com.hazelkahlil.displayvolume.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: device.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try checkAudio(
                AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate),
                L10n.text("连接音频处理与显示器", "Create aggregate route")
            )

            let spec = try validateFormats()
            guard let state = GainCreate(spec.sampleRate, spec.channels) else {
                throw AudioFailure(operation: L10n.text("分配音频处理缓冲", "Allocate gain state"), status: kAudioHardwareUnspecifiedError)
            }
            gain = state
            if let immediateVolume {
                GainSetVolume(state, Float(immediateVolume))
                GainEnableOutput(state)
            }
            installFormatListener(streamID: spec.outputStream)
            try checkAudio(GainInstallIOProc(aggregate, state, &callback), L10n.text("安装音频回调", "Install IOProc"))
            try checkAudio(AudioDeviceStart(aggregate, callback), L10n.text("启动音频处理", "Start audio route"))
            started = true
        } catch {
            stop()
            throw error
        }
    }

    func activate(volume: Double) throws {
        guard let gain, let description = tapDescription, GainSawSignal(gain), !GainHasLayoutError(gain) else {
            throw AudioFailure(operation: L10n.text("验证系统音频", "Verify system audio"), status: kAudioHardwareNotReadyError)
        }
        setVolume(volume)
        description.muteBehavior = .mutedWhenTapped
        var property = audioAddress(kAudioTapPropertyDescription)
        var value = Unmanaged.passUnretained(description)
        try checkAudio(
            AudioObjectSetPropertyData(tap, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value),
            L10n.text("启用软件音量", "Enable software mute tap")
        )
        GainEnableOutput(gain)
    }

    func setVolume(_ fraction: Double) {
        if let gain { GainSetVolume(gain, Float(fraction)) }
    }

    var hasSignal: Bool { gain.map(GainSawSignal) ?? false }
    var layoutChanged: Bool { gain.map(GainHasLayoutError) ?? false }
    var callbackCount: UInt32 { gain.map(GainCallbackCount) ?? 0 }

    func stop() {
        removeFormatListener()
        if let callback {
            if started { AudioDeviceStop(aggregate, callback) }
            AudioDeviceDestroyIOProcID(aggregate, callback)
            self.callback = nil
        }
        started = false
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
        if let gain { GainDestroy(gain) }
        gain = nil
        tapDescription = nil
    }

    private func installFormatListener(streamID: AudioStreamID) {
        removeFormatListener()
        outputStreamID = streamID
        var prop = audioAddress(kAudioStreamPropertyVirtualFormat)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onStreamFormatChanged?()
        }
        if AudioObjectAddPropertyListenerBlock(streamID, &prop, DispatchQueue.main, block) == noErr {
            formatListenerBlock = block
        }
    }

    private func removeFormatListener() {
        if let block = formatListenerBlock, outputStreamID != kAudioObjectUnknown {
            var prop = audioAddress(kAudioStreamPropertyVirtualFormat)
            AudioObjectRemovePropertyListenerBlock(outputStreamID, &prop, DispatchQueue.main, block)
        }
        formatListenerBlock = nil
        outputStreamID = kAudioObjectUnknown
    }

    private static func audioProcessID() throws -> AudioObjectID {
        var property = audioAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: result))
        try checkAudio(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &property,
                UInt32(MemoryLayout.size(ofValue: pid)),
                &pid,
                &size,
                &result
            ),
            L10n.text("识别音频处理进程", "Resolve process object")
        )
        guard result != kAudioObjectUnknown else {
            throw AudioFailure(operation: L10n.text("识别音频处理进程", "Resolve process object"), status: kAudioHardwareBadObjectError)
        }
        return result
    }

    private func validateFormats() throws -> (sampleRate: Double, channels: UInt32, outputStream: AudioStreamID) {
        let inputStreams = try Self.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        let outputStreams = try Self.streams(aggregate, scope: kAudioObjectPropertyScopeOutput)
        guard inputStreams.count == 1, outputStreams.count == 1 else { throw Self.unsupportedFormat }

        var capture = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: capture))
        var property = audioAddress(kAudioTapPropertyFormat)
        try checkAudio(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &capture), L10n.text("读取捕获格式", "Read tap format"))

        let inputFormat = try Self.streamFormat(inputStreams[0])
        let outputFormat = try Self.streamFormat(outputStreams[0])
        guard Self.isSupportedFloatPCM(capture),
              Self.isSupportedFloatPCM(inputFormat),
              Self.isSupportedFloatPCM(outputFormat),
              capture.mChannelsPerFrame == inputFormat.mChannelsPerFrame,
              capture.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
              capture.mSampleRate == inputFormat.mSampleRate,
              capture.mSampleRate == outputFormat.mSampleRate else {
            throw Self.unsupportedFormat
        }
        return (outputFormat.mSampleRate, outputFormat.mChannelsPerFrame, outputStreams[0])
    }

    private static var unsupportedFormat: AudioFailure {
        AudioFailure(operation: L10n.text("匹配输出设备的 PCM 音频格式", "Match PCM output format"), status: kAudioDeviceUnsupportedFormatError)
    }

    private static func streams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamID] {
        var property = audioAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), L10n.text("读取音频通道", "Read audio streams"))
        guard size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.stride)
        try ids.withUnsafeMutableBytes { buffer in
            try checkAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, buffer.baseAddress!), L10n.text("读取音频通道", "Read audio streams"))
        }
        return ids
    }

    private static func streamFormat(_ id: AudioStreamID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        var property = audioAddress(kAudioStreamPropertyVirtualFormat)
        try checkAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &format), L10n.text("读取音频格式", "Read stream format"))
        return format
    }

    private static func isSupportedFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let ch = format.mChannelsPerFrame
        guard ch >= 1 && ch <= 8 else { return false }
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mFormatFlags & kAudioFormatFlagIsPacked != 0
            && format.mBitsPerChannel == 32
            && format.mBytesPerFrame == (planar ? 4 : 4 * ch)
            && format.mFramesPerPacket == 1
            && format.mSampleRate.isFinite
            && (8_000...384_000).contains(format.mSampleRate)
    }
}
