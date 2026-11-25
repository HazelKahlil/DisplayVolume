import AppKit
import CoreAudio
import CryptoKit
import OSLog
import SwiftUI

@inline(__always)
@discardableResult
private func assignIfChanged<T: Equatable>(_ target: inout T, _ newValue: T) -> Bool {
    guard target != newValue else { return false }
    target = newValue
    return true
}

@MainActor
final class VolumeController: NSObject, ObservableObject {
    @Published private(set) var state = VolumeIPC.read()
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var currentOutputDevice: AudioDeviceInfo? = OutputDeviceCatalog.currentDefault()
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var currentInputDevice: AudioDeviceInfo? = InputDeviceCatalog.currentDefault()
    @Published private(set) var uiAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted

    // Software output optimistic state (for DisplayPort/HDMI locked monitors)
    @Published private var optimisticVolume: Int?
    @Published private var optimisticLimit: Int?
    @Published private var optimisticMuted: Bool?

    // Native hardware output state (for MacBook speakers / AirPods / USB DACs)
    @Published private(set) var nativeOutputVolume: Int = 50
    @Published private(set) var nativeOutputMuted: Bool = false

    // Microphone / Input state
    @Published private(set) var inputVolume: Int = 50
    @Published private(set) var inputMuted: Bool = false
    @Published private(set) var inputVolumeWritable: Bool = false
    @Published private(set) var inputMuteSupported: Bool = false
    @Published private(set) var inputUsesSoftMute: Bool = false

    private var volumeLockUntil: TimeInterval = 0
    private var limitLockUntil: TimeInterval = 0
    private var nativeOutLockUntil: TimeInterval = 0
    private var inputLockUntil: TimeInterval = 0
    private var isDraggingVolume = false
    private var isDraggingLimit = false
    private var isDraggingNativeOut = false
    private var isDraggingInput = false
    private var lastVolumeIPCSentAt: TimeInterval = 0
    private var lastLimitIPCSentAt: TimeInterval = 0
    private var lastNativeOutHALSentAt: TimeInterval = 0
    private var lastInputHALSentAt: TimeInterval = 0
    private var lastFullRefreshAt: TimeInterval = 0
    private var lastStateFileModDate: Date?

    private var heartbeat: Timer?
    private var axPollTimer: Timer?
    private var deviceListDebounceWorkItem: DispatchWorkItem?
    private var scrollAccumulator: CGFloat = 0

    // CoreAudio HAL listeners for zero-latency sync with macOS System Settings & Control Center
    private var systemListenersInstalled = false
    private var systemDefaultOutBlock: AudioObjectPropertyListenerBlock?
    private var systemDefaultInBlock: AudioObjectPropertyListenerBlock?
    private var systemDevicesBlock: AudioObjectPropertyListenerBlock?

    private var observedNativeOutID: AudioDeviceID = kAudioObjectUnknown
    private var nativeOutListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private var observedInputID: AudioDeviceID = kAudioObjectUnknown
    private var inputListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    var onChange: (() -> Void)?

    private lazy var uiMediaKeyTap = MediaKeyTap { [weak self] action in
        self?.handleMediaKeyAction(action)
    }

    // MARK: - Derived Output State

    var phase: VolumeState.Phase { state?.phase ?? .idle }
    var volumeLimit: Int { optimisticLimit ?? state?.volumeLimit ?? 100 }
    var muted: Bool { optimisticMuted ?? state?.muted ?? false }
    var volume: Int { min(volumeLimit, optimisticVolume ?? state?.volume ?? 50) }
    var message: String? { state?.message }
    var shownVolume: Int { muted ? 0 : min(volume, volumeLimit) }
    var shortcutsAvailable: Bool { state?.shortcutsAvailable ?? false }
    var mediaKeysAuthorized: Bool { uiAccessibilityTrusted || (state?.mediaKeysAuthorized ?? false) }
    var mediaKeysActive: Bool { uiMediaKeyTap.isRunning || (state?.mediaKeysActive ?? false) }
    var showOSD: Bool { state?.showOSD ?? true }
    var showMenuBarPercent: Bool { state?.showMenuBarPercent ?? false }
    var scrollOnIconEnabled: Bool { state?.scrollOnIconEnabled ?? true }
    var deviceUID: String? { currentOutputDevice?.uid ?? state?.deviceUID }
    var deviceName: String? { currentOutputDevice?.name ?? state?.deviceName }
    var transportLabel: String? { currentOutputDevice?.transportKind.displayLabel ?? state?.transportLabel }
    var isEngineConnected: Bool { state != nil }
    var isControllable: Bool { state?.isControllable ?? (currentOutputDevice?.isAutoControllable ?? false) }
    var isEnabled: Bool { state?.enabled ?? false }

    var isSoftwareOutputActive: Bool { phase == .active && isControllable }
    var isNativeHardwareOutput: Bool { !isControllable && (currentOutputDevice?.volumeControlAvailable == true) }
    var canControlCurrentOutput: Bool { isSoftwareOutputActive || isNativeHardwareOutput }

    var effectiveOutputVolume: Int {
        if isSoftwareOutputActive { return shownVolume }
        if isNativeHardwareOutput { return nativeOutputMuted ? 0 : nativeOutputVolume }
        return 0
    }

    var effectiveOutputLimit: Int {
        isSoftwareOutputActive ? volumeLimit : 100
    }

    var effectiveOutputMuted: Bool {
        if isSoftwareOutputActive { return muted }
        if isNativeHardwareOutput { return nativeOutputMuted }
        return false
    }

    var shownInputVolume: Int {
        inputMuted ? 0 : inputVolume
    }

    // MARK: - Lifecycle

    func beginMonitoring() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStateNotification(_:)),
            name: VolumeIPC.changed,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // Event-driven listeners handle real-time sync; keep a low-cost 30s safety heartbeat.
        let timer = Timer(timeInterval: 30.0, target: self, selector: #selector(pollFallback), userInfo: nil, repeats: true)
        timer.tolerance = 5.0
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        installSystemAudioListeners()
        refreshAllAudioDevices(force: true)
        syncUIMediaKeyTap()
    }

    func shutDown() {
        heartbeat?.invalidate()
        heartbeat = nil
        axPollTimer?.invalidate()
        axPollTimer = nil
        deviceListDebounceWorkItem?.cancel()
        deviceListDebounceWorkItem = nil
        removeSystemAudioListeners()
        if uiMediaKeyTap.isRunning {
            VolumeIPC.send(.setUIMediaKeysActive, flag: false)
        }
        uiMediaKeyTap.stop()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Device & Hardware Sync

    func refreshIfStale(maxAge: TimeInterval = 0.12) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFullRefreshAt >= maxAge {
            refreshAllAudioDevices(force: true)
        }
    }

    /// Single-pass CoreAudio HAL snapshot refresh: enumerates all devices once instead of 4x per popover open.
    func refreshAllAudioDevices(force: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastFullRefreshAt < 0.12 { return }
        lastFullRefreshAt = now

        let snapshot = AudioDeviceCatalog.captureSnapshot()
        var changed = false
        changed = assignIfChanged(&outputDevices, snapshot.outputDevices) || changed
        changed = assignIfChanged(&currentOutputDevice, snapshot.defaultOutput) || changed
        changed = assignIfChanged(&inputDevices, snapshot.inputDevices) || changed
        changed = assignIfChanged(&currentInputDevice, snapshot.defaultInput) || changed

        installNativeOutputListeners(for: snapshot.defaultOutput)
        installInputListeners(for: snapshot.defaultInput)
        changed = syncNativeOutputHardwareState(force: false) || changed
        changed = syncInputHardwareState(force: false) || changed
        if changed {
            onChange?()
        }
    }

    func refreshOutputDevices() {
        var changed = false
        changed = assignIfChanged(&outputDevices, OutputDeviceCatalog.allOutputDevices()) || changed
        changed = assignIfChanged(&currentOutputDevice, OutputDeviceCatalog.currentDefault()) || changed
        installNativeOutputListeners(for: currentOutputDevice)
        changed = syncNativeOutputHardwareState(force: false) || changed
        if changed {
            onChange?()
        }
    }

    func refreshInputDevices() {
        var changed = false
        changed = assignIfChanged(&inputDevices, InputDeviceCatalog.allInputDevices()) || changed
        changed = assignIfChanged(&currentInputDevice, InputDeviceCatalog.currentDefault()) || changed
        installInputListeners(for: currentInputDevice)
        changed = syncInputHardwareState(force: false) || changed
        if changed {
            onChange?()
        }
    }

    func refreshAccessibilityState() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        if assignIfChanged(&uiAccessibilityTrusted, trusted) {
            onChange?()
        }
        syncUIMediaKeyTap()
    }

    func selectOutputDevice(uid: String) {
        let switched: Bool
        if let cached = outputDevices.first(where: { $0.uid == uid }) {
            switched = OutputDeviceCatalog.setDefaultOutput(deviceID: cached.id)
        } else {
            switched = OutputDeviceCatalog.setDefaultOutput(uid: uid)
        }
        if switched {
            nativeOutLockUntil = 0
            refreshOutputDevices()
        }
    }

    func selectInputDevice(uid: String) {
        let switched: Bool
        if let cached = inputDevices.first(where: { $0.uid == uid }) {
            switched = InputDeviceCatalog.setDefaultInput(deviceID: cached.id)
        } else {
            switched = InputDeviceCatalog.setDefaultInput(uid: uid)
        }
        if switched {
            inputLockUntil = 0
            refreshInputDevices()
        }
    }

    @discardableResult
    private func syncNativeOutputHardwareState(force: Bool) -> Bool {
        guard let dev = currentOutputDevice, dev.volumeControlAvailable else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (!isDraggingNativeOut && now >= nativeOutLockUntil) else { return false }

        var changed = false
        if let scalar = AudioHardwareControl.readScalarVolume(
            deviceID: dev.id,
            scope: kAudioDevicePropertyScopeOutput,
            channelCount: dev.outputChannels
        ) {
            changed = assignIfChanged(&nativeOutputVolume, Int((scalar * 100.0).rounded())) || changed
        }
        if let hwMuted = AudioHardwareControl.readMute(
            deviceID: dev.id,
            scope: kAudioDevicePropertyScopeOutput,
            channelCount: dev.outputChannels
        ) {
            changed = assignIfChanged(&nativeOutputMuted, hwMuted) || changed
        } else {
            changed = assignIfChanged(&nativeOutputMuted, nativeOutputVolume == 0) || changed
        }
        return changed
    }

    @discardableResult
    private func syncInputHardwareState(force: Bool) -> Bool {
        guard let mic = currentInputDevice else {
            var changed = false
            changed = assignIfChanged(&inputVolume, 0) || changed
            changed = assignIfChanged(&inputMuted, false) || changed
            changed = assignIfChanged(&inputVolumeWritable, false) || changed
            changed = assignIfChanged(&inputMuteSupported, false) || changed
            changed = assignIfChanged(&inputUsesSoftMute, false) || changed
            return changed
        }
        let now = ProcessInfo.processInfo.systemUptime
        let status = MicrophoneControl.readStatus(for: mic)
        var changed = false
        changed = assignIfChanged(&inputVolumeWritable, status.volumeWritable) || changed
        changed = assignIfChanged(&inputMuteSupported, status.muteSupported) || changed
        changed = assignIfChanged(&inputUsesSoftMute, status.usesSoftMute) || changed
        guard force || (!isDraggingInput && now >= inputLockUntil) else { return changed }
        changed = assignIfChanged(&inputVolume, status.volumePercent) || changed
        changed = assignIfChanged(&inputMuted, status.muted) || changed
        return changed
    }

    // MARK: - CoreAudio Property Listeners

    private func installSystemAudioListeners() {
        guard !systemListenersInstalled else { return }
        systemListenersInstalled = true

        var outAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshOutputDevices() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddr, DispatchQueue.main, outBlock) == noErr {
            systemDefaultOutBlock = outBlock
        }

        var inAddr = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        let inBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshInputDevices() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inAddr, DispatchQueue.main, inBlock) == noErr {
            systemDefaultInBlock = inBlock
        }

        var devAddr = audioAddress(kAudioHardwarePropertyDevices)
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleDeviceTopologyRefresh() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main, devBlock) == noErr {
            systemDevicesBlock = devBlock
        }
    }

    private func scheduleDeviceTopologyRefresh() {
        deviceListDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.deviceListDebounceWorkItem = nil
            self?.refreshAllAudioDevices(force: true)
        }
        deviceListDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func removeSystemAudioListeners() {
        removeNativeOutputListeners()
        removeInputListeners()
        if let block = systemDefaultOutBlock {
            var addr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        if let block = systemDefaultInBlock {
            var addr = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        if let block = systemDevicesBlock {
            var addr = audioAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        systemDefaultOutBlock = nil
        systemDefaultInBlock = nil
        systemDevicesBlock = nil
        systemListenersInstalled = false
    }

    private func installNativeOutputListeners(for device: AudioDeviceInfo?) {
        let targetID = (device?.volumeControlAvailable == true) ? device!.id : AudioDeviceID(kAudioObjectUnknown)
        if observedNativeOutID == targetID { return }
        removeNativeOutputListeners()
        guard targetID != kAudioObjectUnknown else { return }
        observedNativeOutID = targetID

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element: UInt32 in [0, 1, 2] {
                var prop = audioAddress(selector, scope: kAudioDevicePropertyScopeOutput, element: element)
                guard AudioObjectHasProperty(targetID, &prop) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor in
                        if self?.syncNativeOutputHardwareState(force: false) == true {
                            self?.onChange?()
                        }
                    }
                }
                if AudioObjectAddPropertyListenerBlock(targetID, &prop, DispatchQueue.main, block) == noErr {
                    nativeOutListeners.append((prop, block))
                }
            }
        }
    }

    private func removeNativeOutputListeners() {
        if observedNativeOutID != kAudioObjectUnknown {
            for (var prop, block) in nativeOutListeners {
                AudioObjectRemovePropertyListenerBlock(observedNativeOutID, &prop, DispatchQueue.main, block)
            }
        }
        nativeOutListeners.removeAll()
        observedNativeOutID = kAudioObjectUnknown
    }

    private func installInputListeners(for device: AudioDeviceInfo?) {
        let targetID = device?.id ?? AudioDeviceID(kAudioObjectUnknown)
        if observedInputID == targetID { return }
        removeInputListeners()
        guard targetID != kAudioObjectUnknown else { return }
        observedInputID = targetID

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element: UInt32 in [0, 1, 2] {
                var prop = audioAddress(selector, scope: kAudioDevicePropertyScopeInput, element: element)
                guard AudioObjectHasProperty(targetID, &prop) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor in
                        if self?.syncInputHardwareState(force: false) == true {
                            self?.onChange?()
                        }
                    }
                }
                if AudioObjectAddPropertyListenerBlock(targetID, &prop, DispatchQueue.main, block) == noErr {
                    inputListeners.append((prop, block))
                }
            }
        }
    }

    private func removeInputListeners() {
        if observedInputID != kAudioObjectUnknown {
            for (var prop, block) in inputListeners {
                AudioObjectRemovePropertyListenerBlock(observedInputID, &prop, DispatchQueue.main, block)
            }
        }
        inputListeners.removeAll()
        observedInputID = kAudioObjectUnknown
    }

    // MARK: - Engine IPC Sync

    @objc private func handleStateNotification(_ notification: Notification) {
        let latest = VolumeIPC.read(from: notification)
        applyIncomingState(latest)
    }

    private func applyIncomingState(_ latest: VolumeState?) {
        let now = ProcessInfo.processInfo.systemUptime
        let externalHardwareTrigger = latest?.lastTriggerSource == .mediaKey
            || latest?.lastTriggerSource == .hotkey
            || latest?.lastTriggerSource == .scroll

        if externalHardwareTrigger || (!isDraggingVolume && now >= volumeLockUntil) {
            assignIfChanged(&optimisticVolume, nil)
            assignIfChanged(&optimisticMuted, nil)
        }
        if !isDraggingLimit && now >= limitLockUntil {
            assignIfChanged(&optimisticLimit, nil)
        }

        if assignIfChanged(&state, latest) {
            syncUIMediaKeyTap()
            if uiMediaKeyTap.isRunning, latest?.mediaKeysActive == false {
                VolumeIPC.send(.setUIMediaKeysActive, flag: true)
            }
            onChange?()
        }
    }

    func refreshFromDisk() {
        lastStateFileModDate = (try? FileManager.default.attributesOfItem(atPath: VolumeIPC.stateFile.path)[.modificationDate]) as? Date
        applyIncomingState(VolumeIPC.read())
    }

    @objc private func pollFallback() {
        // Fast-path: skip disk I/O and JSON decoding when engine PID is alive and state.json mtime is unchanged.
        let currentMod = (try? FileManager.default.attributesOfItem(atPath: VolumeIPC.stateFile.path)[.modificationDate]) as? Date
        let engineAlive = (state?.enginePID ?? 0) > 0 && kill(state!.enginePID, 0) == 0
        if !engineAlive || currentMod == nil || currentMod != lastStateFileModDate {
            lastStateFileModDate = currentMod
            applyIncomingState(VolumeIPC.read())
        }
        if !uiAccessibilityTrusted {
            refreshAccessibilityState()
        }
    }

    // MARK: - Media Keys & Scroll

    private func syncUIMediaKeyTap() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        assignIfChanged(&uiAccessibilityTrusted, trusted)
        if trusted {
            axPollTimer?.invalidate()
            axPollTimer = nil
            if !uiMediaKeyTap.isRunning {
                if uiMediaKeyTap.start() {
                    VolumeIPC.send(.setUIMediaKeysActive, flag: true)
                }
            }
            let shouldIntercept = isEnabled && (phase == .active || phase == .checking) && isControllable
            uiMediaKeyTap.shouldIntercept = uiMediaKeyTap.isRunning && shouldIntercept
        } else {
            if uiMediaKeyTap.isRunning {
                uiMediaKeyTap.stop()
                VolumeIPC.send(.setUIMediaKeysActive, flag: false)
            }
            startAccessibilityPollingIfNeeded()
        }
    }

    private func startAccessibilityPollingIfNeeded() {
        guard axPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.9, target: self, selector: #selector(checkAccessibilityPoll), userInfo: nil, repeats: true)
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        axPollTimer = timer
    }

    @objc private func checkAccessibilityPoll() {
        if MediaKeyTap.isAccessibilityTrusted {
            refreshAccessibilityState()
        }
    }

    private func handleMediaKeyAction(_ action: MediaKeyAction) {
        guard phase == .active || phase == .checking else { return }
        switch action {
        case .volumeUp(let fine):
            VolumeIPC.send(.step, value: fine ? 1 : 5, source: .mediaKey)
        case .volumeDown(let fine):
            VolumeIPC.send(.step, value: fine ? -1 : -5, source: .mediaKey)
        case .toggleMute:
            VolumeIPC.send(.mute, source: .mediaKey)
        }
    }

    func handleScrollDelta(_ deltaY: CGFloat) {
        guard scrollOnIconEnabled else { return }
        scrollAccumulator += deltaY
        let stepThreshold: CGFloat = 4.0
        guard abs(scrollAccumulator) >= stepThreshold else { return }
        let steps = Int((scrollAccumulator / stepThreshold).rounded(.towardZero))
        scrollAccumulator -= CGFloat(steps) * stepThreshold
        guard steps != 0 else { return }

        if isSoftwareOutputActive {
            VolumeIPC.send(.step, value: steps * 2, source: .scroll)
        } else if isNativeHardwareOutput {
            let next = VolumeMath.applyStep(
                currentVolume: nativeOutputVolume,
                limit: 100,
                muted: nativeOutputMuted,
                delta: steps * 2
            )
            setNativeOutputVolume(next.muted ? 0 : next.volume, isDragging: false)
        }
    }

    // MARK: - Output Mutations (Software + Native Hardware)

    func enable() { VolumeIPC.send(.enable) }
    func disable() { VolumeIPC.send(.pause) }

    func setActiveOutputVolume(_ percent: Int, isDragging: Bool = false) {
        if isSoftwareOutputActive {
            setVolume(percent, isDragging: isDragging)
        } else if isNativeHardwareOutput {
            setNativeOutputVolume(percent, isDragging: isDragging)
        }
    }

    func toggleActiveOutputMute() {
        if isSoftwareOutputActive {
            toggleMute()
        } else if isNativeHardwareOutput {
            toggleNativeOutputMute()
        }
    }

    func setVolume(_ percent: Int, isDragging: Bool = false) {
        let clamped = VolumeMath.clampedVolume(percent, limit: volumeLimit)
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingVolume = isDragging
        volumeLockUntil = now + 0.30
        if clamped > 0 {
            assignIfChanged(&optimisticVolume, clamped)
            assignIfChanged(&optimisticMuted, false)
        } else {
            assignIfChanged(&optimisticMuted, true)
        }
        onChange?()

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastVolumeIPCSentAt, minInterval: 0.025, isDragging: isDragging) {
            lastVolumeIPCSentAt = now
            VolumeIPC.send(.volume, value: clamped, source: .slider)
        }
    }

    func setVolumeLimit(_ percent: Int, isDragging: Bool = false) {
        let clamped = min(100, max(1, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingLimit = isDragging
        limitLockUntil = now + 0.30
        assignIfChanged(&optimisticLimit, clamped)
        if let v = optimisticVolume, v > clamped {
            assignIfChanged(&optimisticVolume, clamped)
        }
        onChange?()

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastLimitIPCSentAt, minInterval: 0.025, isDragging: isDragging) {
            lastLimitIPCSentAt = now
            VolumeIPC.send(.limit, value: clamped)
        }
    }

    func toggleMute() {
        let now = ProcessInfo.processInfo.systemUptime
        volumeLockUntil = now + 0.25
        assignIfChanged(&optimisticMuted, !muted)
        onChange?()
        VolumeIPC.send(.mute, source: .slider)
    }

    func setNativeOutputVolume(_ percent: Int, isDragging: Bool = false) {
        guard let dev = currentOutputDevice, dev.volumeControlAvailable else { return }
        let clamped = min(100, max(0, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingNativeOut = isDragging
        nativeOutLockUntil = now + 0.25
        assignIfChanged(&nativeOutputVolume, clamped)
        assignIfChanged(&nativeOutputMuted, clamped == 0)

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastNativeOutHALSentAt, minInterval: 0.020, isDragging: isDragging) {
            lastNativeOutHALSentAt = now
            _ = AudioHardwareControl.writeScalarVolume(
                deviceID: dev.id,
                scope: kAudioDevicePropertyScopeOutput,
                channelCount: dev.outputChannels,
                fraction: Float(clamped) / 100.0
            )
            if dev.muteControlAvailable {
                _ = AudioHardwareControl.writeMute(
                    deviceID: dev.id,
                    scope: kAudioDevicePropertyScopeOutput,
                    channelCount: dev.outputChannels,
                    muted: clamped == 0
                )
            }
        }
        onChange?()
    }

    func toggleNativeOutputMute() {
        guard let dev = currentOutputDevice, dev.volumeControlAvailable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        nativeOutLockUntil = now + 0.25
        let targetMuted = !nativeOutputMuted
        assignIfChanged(&nativeOutputMuted, targetMuted)

        if dev.muteControlAvailable {
            _ = AudioHardwareControl.writeMute(
                deviceID: dev.id,
                scope: kAudioDevicePropertyScopeOutput,
                channelCount: dev.outputChannels,
                muted: targetMuted
            )
            if !targetMuted && nativeOutputVolume == 0 {
                assignIfChanged(&nativeOutputVolume, 25)
                _ = AudioHardwareControl.writeScalarVolume(
                    deviceID: dev.id,
                    scope: kAudioDevicePropertyScopeOutput,
                    channelCount: dev.outputChannels,
                    fraction: 0.25
                )
            }
        } else {
            let applied = targetMuted ? 0 : max(10, nativeOutputVolume)
            _ = AudioHardwareControl.writeScalarVolume(
                deviceID: dev.id,
                scope: kAudioDevicePropertyScopeOutput,
                channelCount: dev.outputChannels,
                fraction: Float(applied) / 100.0
            )
        }
        onChange?()
    }

    // MARK: - Input / Microphone Mutations

    func setInputVolume(_ percent: Int, isDragging: Bool = false) {
        guard let mic = currentInputDevice, mic.inputVolumeControlAvailable else { return }
        let clamped = min(100, max(0, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingInput = isDragging
        inputLockUntil = now + 0.25
        if clamped > 0 {
            assignIfChanged(&inputVolume, clamped)
            assignIfChanged(&inputMuted, false)
        } else {
            assignIfChanged(&inputVolume, clamped)
            if !mic.inputMuteControlAvailable {
                assignIfChanged(&inputMuted, true)
            }
        }

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastInputHALSentAt, minInterval: 0.020, isDragging: isDragging) {
            lastInputHALSentAt = now
            // Never write UserDefaults plist to disk on every pixel drag; persist only on drag end / discrete change.
            MicrophoneControl.applyVolume(clamped, for: mic, persistPreMute: !isDragging)
        }
        onChange?()
    }

    func toggleInputMute(showOSD: Bool = false) {
        guard let mic = currentInputDevice, mic.inputMuteSupported else { return }
        let now = ProcessInfo.processInfo.systemUptime
        inputLockUntil = now + 0.25
        if let updated = MicrophoneControl.toggleMute(for: mic) {
            assignIfChanged(&inputVolume, updated.volumePercent)
            assignIfChanged(&inputMuted, updated.muted)
            if showOSD {
                VolumeIPC.send(.showMicOSD)
            }
            onChange?()
        }
    }

    // MARK: - Accessibility & Preferences

    func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        _ = MediaKeyTap.requestAccessibilityPrompt()
        refreshAccessibilityState()
        if !MediaKeyTap.isAccessibilityTrusted {
            startAccessibilityPollingIfNeeded()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func setShowOSD(_ flag: Bool) { VolumeIPC.send(.setShowOSD, flag: flag) }
    func setShowMenuBarPercent(_ flag: Bool) { VolumeIPC.send(.setShowMenuBarPercent, flag: flag) }
    func setScrollOnIcon(_ flag: Bool) { VolumeIPC.send(.setScrollOnIcon, flag: flag) }
}

/// Manages installing the embedded background engine and LaunchAgent so the app works out-of-the-box for all users.
enum EngineProvisioner {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DisplayVolume", isDirectory: true)
    static let installedEngineURL = supportDir.appendingPathComponent("DisplayVolumeEngine.app", isDirectory: true)
    static let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    static let plistURL = launchAgentDir.appendingPathComponent("\(VolumeIPC.engineBundleID).plist")
    static let legacyPlistURL = launchAgentDir.appendingPathComponent("\(VolumeIPC.legacyEngineBundleID).plist")

    static func ensureInstalledAndRunning() {
        cleanLegacyEngineIfPresent()

        guard let embeddedURL = embeddedEngineURL() else {
            return
        }

        let needsInstall = shouldUpdateInstalledEngine(embedded: embeddedURL, installed: installedEngineURL)
        if needsInstall {
            bootOut(label: VolumeIPC.engineBundleID, plist: plistURL)
            terminateProcess(bundleIdentifier: VolumeIPC.engineBundleID)
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: installedEngineURL)
            do {
                try FileManager.default.copyItem(at: embeddedURL, to: installedEngineURL)
            } catch {
                NSLog("Failed to install DisplayVolumeEngine: %@", error.localizedDescription)
                return
            }
        }

        ensureLaunchAgentPlist()
        if needsInstall || VolumeIPC.read() == nil {
            bootstrapLaunchAgent()
        }
    }

    static func uninstallAndStopEngine() {
        bootOut(label: VolumeIPC.engineBundleID, plist: plistURL)
        terminateProcess(bundleIdentifier: VolumeIPC.engineBundleID)
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: installedEngineURL)
    }

    private static func embeddedEngineURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/DisplayVolumeEngine.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func shouldUpdateInstalledEngine(embedded: URL, installed: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: installed.path) else { return true }
        let embeddedPlist = Bundle(url: embedded)?.infoDictionary
        let installedPlist = Bundle(url: installed)?.infoDictionary
        if (embeddedPlist?["CFBundleVersion"] as? String) != (installedPlist?["CFBundleVersion"] as? String) {
            return true
        }
        let bin1 = embedded.appendingPathComponent("Contents/MacOS/DisplayVolumeEngine")
        let bin2 = installed.appendingPathComponent("Contents/MacOS/DisplayVolumeEngine")
        guard let d1 = try? Data(contentsOf: bin1), let d2 = try? Data(contentsOf: bin2) else {
            return true
        }
        return SHA256.hash(data: d1) != SHA256.hash(data: d2)
    }

    private static func ensureLaunchAgentPlist() {
        let executablePath = installedEngineURL.appendingPathComponent("Contents/MacOS/DisplayVolumeEngine").path
        let dict: [String: Any] = [
            "Label": VolumeIPC.engineBundleID,
            "ProgramArguments": [executablePath],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5
        ]
        try? FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        if let data {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    private static func cleanLegacyEngineIfPresent() {
        if FileManager.default.fileExists(atPath: legacyPlistURL.path) {
            bootOut(label: VolumeIPC.legacyEngineBundleID, plist: legacyPlistURL)
            try? FileManager.default.removeItem(at: legacyPlistURL)
        }
        terminateProcess(bundleIdentifier: VolumeIPC.legacyEngineBundleID)
        terminateProcess(bundleIdentifier: "local.kahlil.RedmiVolume")
    }

    private static func bootOut(label: String, plist: URL) {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
        _ = runLaunchctl(["bootout", domain, plist.path])
    }

    private static func bootstrapLaunchAgent() {
        let domain = "gui/\(getuid())"
        let status = runLaunchctl(["bootstrap", domain, plistURL.path])
        if status != 0 {
            _ = runLaunchctl(["kickstart", "-k", "\(domain)/\(VolumeIPC.engineBundleID)"])
        }
    }

    private static func terminateProcess(bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            if app.processIdentifier != getpid() {
                app.terminate()
            }
        }
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private struct StatusItemRenderKey: Equatable {
        let volume: Int
        let muted: Bool
        let active: Bool
        let showPercent: Bool
        let inputMuted: Bool
    }

    private let model = VolumeController()
    private let log = Logger(subsystem: VolumeIPC.suiteName, category: "DisplayVolumeUI")
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var lastStatusRenderKey: StatusItemRenderKey?
    private var scrollMonitor: Any?
    private var sleepObserver: NSObjectProtocol?

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTestSuite()
            return
        }
        if CommandLine.arguments.contains("--bench") {
            runLatencyBenchmark()
            return
        }
        if CommandLine.arguments.contains("--engine-status") {
            guard let state = VolumeIPC.read() else {
                print("Audio engine unavailable")
                exit(1)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try! encoder.encode(state)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let snapshot = AudioDeviceCatalog.captureSnapshot()
            let outputs = snapshot.outputDevices
            let currentOut = snapshot.defaultOutput
            let inputs = snapshot.inputDevices
            let currentIn = snapshot.defaultInput

            print("Default output: \(currentOut?.name ?? "None") (\(currentOut?.transportKind.displayLabel ?? "-"))")
            print("  Native scalar volume: \(currentOut?.volumeControlAvailable ?? false), mute: \(currentOut?.muteControlAvailable ?? false)")
            print("  Auto-controllable (software): \(currentOut?.isAutoControllable ?? false)")
            if let currentIn {
                let micStatus = MicrophoneControl.readStatus(for: currentIn)
                print("Default input: \(currentIn.name) (\(currentIn.transportKind.displayLabel))")
                print("  Input volume: \(micStatus.volumePercent)% (writable=\(micStatus.volumeWritable)), muted=\(micStatus.muted) (muteSupported=\(micStatus.muteSupported), softMute=\(micStatus.usesSoftMute))")
            } else {
                print("Default input: None")
            }
            print("UI Accessibility trusted: \(MediaKeyTap.isAccessibilityTrusted)")
            print("All outputs (\(outputs.count)):")
            for dev in outputs {
                print("  - \(dev.name) [\(dev.transportKind.displayLabel)] sw=\(dev.isAutoControllable) hwVol=\(dev.volumeControlAvailable)")
            }
            print("All inputs (\(inputs.count)):")
            for dev in inputs {
                print("  - \(dev.name) [\(dev.transportKind.displayLabel)] inVol=\(dev.inputVolumeControlAvailable) inMute=\(dev.inputMuteControlAvailable)")
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateDuplicateUIInstances()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                model: model,
                onHideIcon: { NSApp.terminate(nil) },
                onQuitAll: { [weak self] in self?.quitCompletely() },
                sizeChanged: { [weak self] size in
                    DispatchQueue.main.async { self?.resizePopover(size) }
                }
            )
        )
        popover.contentSize = NSSize(width: 312, height: 420)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let btn = item.button {
            btn.target = self
            btn.action = #selector(handleStatusClick(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.setAccessibilityIdentifier("DisplayVolumeStatusItem")
        }

        model.onChange = { [weak self] in self?.updateStatusItemAppearance() }
        model.beginMonitoring()
        model.refreshFromDisk()
        updateStatusItemAppearance()

        // Provision / update embedded LaunchAgent engine off the main thread so menu bar icon appears immediately.
        DispatchQueue.global(qos: .userInitiated).async {
            EngineProvisioner.ensureInstalledAndRunning()
            DispatchQueue.main.async { [weak self] in
                self?.model.refreshFromDisk()
            }
        }

        installScrollMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }

        if CommandLine.arguments.contains("--open-popover") || (model.isControllable && model.phase != .active) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        closePopover()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        NotificationCenter.default.removeObserver(self)
        model.shutDown()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    private func terminateDuplicateUIInstances() {
        let myPID = getpid()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: VolumeIPC.suiteName) where app.processIdentifier != myPID {
            app.terminate()
        }
    }

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  !self.popover.isShown,
                  let button = self.statusItem?.button,
                  let window = button.window else {
                return event
            }
            if event.window === window {
                let delta = event.scrollingDeltaY
                let step = event.hasPreciseScrollingDeltas ? delta * 0.35 : delta * 4.0
                MainActor.assumeIsolated {
                    self.model.handleScrollDelta(step)
                }
            }
            return event
        }
    }

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickContextMenu(sender)
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            model.refreshFromDisk()
            model.refreshAllAudioDevices()
            model.refreshAccessibilityState()
            showPopover()
        }
    }

    private func showQuickContextMenu(_ button: NSStatusBarButton) {
        closePopover()
        model.refreshAllAudioDevices()

        let menu = NSMenu()
        if model.canControlCurrentOutput {
            let muteTitle = model.effectiveOutputMuted
                ? L10n.text("取消静音输出", "Unmute Output")
                : L10n.text("静音输出", "Mute Output")
            let muteItem = NSMenuItem(title: muteTitle, action: #selector(menuToggleOutputMute), keyEquivalent: "")
            muteItem.target = self
            menu.addItem(muteItem)
        }
        if model.inputMuteSupported {
            let micTitle = model.inputMuted
                ? L10n.text("取消静音麦克风", "Unmute Microphone")
                : L10n.text("静音麦克风", "Mute Microphone")
            let micItem = NSMenuItem(title: micTitle, action: #selector(menuToggleMicMute), keyEquivalent: "")
            micItem.target = self
            menu.addItem(micItem)
        }
        if model.isControllable {
            let toggleTitle = model.isEnabled
                ? L10n.text("暂停软件音量", "Pause Software Volume")
                : L10n.text("启用软件音量", "Enable Software Volume")
            let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(menuToggleEnable), keyEquivalent: "")
            toggleItem.target = self
            menu.addItem(toggleItem)
        }
        menu.addItem(.separator())
        let hideItem = NSMenuItem(title: L10n.text("隐藏菜单栏图标（后台继续）", "Hide Icon (Keep Engine)"), action: #selector(menuHideIcon), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        let quitAllItem = NSMenuItem(title: L10n.text("完全退出并停用后台", "Quit & Stop Engine"), action: #selector(menuQuitAll), keyEquivalent: "q")
        quitAllItem.target = self
        menu.addItem(quitAllItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuToggleOutputMute() { model.toggleActiveOutputMute() }
    @objc private func menuToggleMicMute() { model.toggleInputMute(showOSD: true) }
    @objc private func menuToggleEnable() {
        if model.isEnabled { model.disable() } else { model.enable() }
    }
    @objc private func menuHideIcon() { NSApp.terminate(nil) }
    @objc private func menuQuitAll() { quitCompletely() }

    private func quitCompletely() {
        closePopover()
        EngineProvisioner.uninstallAndStopEngine()
        NSApp.terminate(nil)
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button, button.window != nil else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(nil)
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let button = statusItem?.button, let statusWindow = button.window,
              let window = popover.contentViewController?.view.window else { return }
        let icon = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = window.frame
        log.info("Popover placed: menuBottom=\(icon.minY), panelTop=\(frame.maxY), size=\(frame.width)x\(frame.height)")
    }

    private func resizePopover(_ size: CGSize) {
        guard size.width > 0, size.height > 0, popover.contentSize != size else { return }
        popover.contentSize = size
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let outActive = model.canControlCurrentOutput
        let renderKey = StatusItemRenderKey(
            volume: model.effectiveOutputVolume,
            muted: model.effectiveOutputMuted,
            active: outActive,
            showPercent: model.showMenuBarPercent,
            inputMuted: model.inputMuted
        )
        guard renderKey != lastStatusRenderKey else { return }
        lastStatusRenderKey = renderKey

        let baseLabel = outActive
            ? (renderKey.muted ? L10n.mutedLabel : "\(L10n.appName) \(renderKey.volume)%")
            : L10n.appName
        let fullLabel = renderKey.inputMuted
            ? "\(baseLabel) · \(L10n.micMutedOSDLabel)"
            : baseLabel

        let image = MenuBarIconRenderer.makeIcon(
            volume: renderKey.volume,
            muted: renderKey.muted,
            active: outActive
        )
        button.image = image
        button.imagePosition = renderKey.showPercent && outActive ? .imageLeading : .imageOnly
        if renderKey.showPercent && outActive {
            let text = renderKey.muted ? L10n.mutedLabel : "\(renderKey.volume)%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            ]
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attrs)
        } else {
            button.title = ""
        }
        button.setAccessibilityLabel(fullLabel)
        button.toolTip = fullLabel
    }
}

private func runLatencyBenchmark() {
    let iterations = 5
    var snapshotTimes: [Double] = []
    var ipcTimes: [Double] = []

    // Warm up CoreAudio HAL proxy map once before measuring steady-state latency.
    _ = AudioDeviceCatalog.captureSnapshot()

    for _ in 0..<iterations {
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = AudioDeviceCatalog.captureSnapshot()
        snapshotTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)

        let t1 = CFAbsoluteTimeGetCurrent()
        _ = VolumeIPC.read()
        ipcTimes.append((CFAbsoluteTimeGetCurrent() - t1) * 1000.0)
    }

    let snapAvg = snapshotTimes.reduce(0, +) / Double(iterations)
    let ipcAvg = ipcTimes.reduce(0, +) / Double(iterations)
    print(String(format: "BENCH single-pass HAL snapshot avg=%.2f ms (budget <= 50.00 ms)", snapAvg))
    print(String(format: "BENCH VolumeIPC.read()         avg=%.2f ms (budget <= 10.00 ms)", ipcAvg))
    let pass = snapAvg <= 50.0 && ipcAvg <= 10.0
    print(pass ? "PASS latency budget" : "FAIL latency budget exceeded")
    exit(pass ? 0 : 1)
}

private func runSelfTestSuite() {
    let clamped1 = VolumeMath.clampedVolume(95, limit: 80) == 80
    let clamped2 = VolumeMath.clampedVolume(-5, limit: 80) == 0
    let step1 = VolumeMath.applyStep(currentVolume: 60, limit: 80, muted: false, delta: 5) == (65, false)
    let step2 = VolumeMath.applyStep(currentVolume: 78, limit: 80, muted: false, delta: 5) == (80, false)
    let step3 = VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: false, delta: -5) == (3, true)
    let step4 = VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: true, delta: 5) == (3, false)
    let step5 = VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: -5) == (40, true)
    let mic1 = InputMuteMath.planSoftMute(currentPercent: 85, savedBeforeMute: nil, targetMuted: true)
        == .init(appliedPercent: 0, updatedSavedVolume: 85)
    let mic2 = InputMuteMath.planSoftMute(currentPercent: 0, savedBeforeMute: 85, targetMuted: false)
        == .init(appliedPercent: 85, updatedSavedVolume: 85)

    let ok = clamped1 && clamped2 && step1 && step2 && step3 && step4 && step5 && mic1 && mic2
    print(ok ? "PASS app volume & microphone math tests" : "FAIL app volume & microphone math tests")
    exit(ok ? 0 : 1)
}
