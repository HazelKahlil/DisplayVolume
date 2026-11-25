import AppKit
import Combine
import CoreAudio
import CryptoKit
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class VolumeController: NSObject, ObservableObject {
    @Published private(set) var state = VolumeIPC.readCachedSnapshot()
    @Published private(set) var xpcConnected = false
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
    @Published private(set) var inputStatusReadable: Bool = true

    private let clientInstanceID = UUID().uuidString
    private let ownIdentity = CodeSignInspector.currentProcessIdentity()
    private var xpcConnection: NSXPCConnection?

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
    private var lastHandledTriggerNonce: UInt64 = 0

    private var heartbeat: Timer?
    private var axPollTimer: Timer?
    private var deviceListDebounceWorkItem: DispatchWorkItem?
    private var trailingReconcileWorkItem: DispatchWorkItem?
    private var scrollAccumulator: CGFloat = 0

    // CoreAudio HAL listeners
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

    /// Only treat Engine software state as applicable when its UID matches the current HAL output device.
    private var stateMatchesCurrentOutput: Bool {
        guard let state else { return false }
        guard let currentUID = currentOutputDevice?.uid else { return true }
        return state.deviceUID == currentUID
    }

    var phase: VolumeState.Phase { stateMatchesCurrentOutput ? (state?.phase ?? .idle) : .idle }
    var volumeLimit: Int { optimisticLimit ?? (stateMatchesCurrentOutput ? state?.volumeLimit : nil) ?? 100 }
    var muted: Bool { optimisticMuted ?? (stateMatchesCurrentOutput ? state?.muted : nil) ?? false }
    var volume: Int { min(volumeLimit, optimisticVolume ?? (stateMatchesCurrentOutput ? state?.volume : nil) ?? 50) }
    var message: String? { state?.message }
    var shownVolume: Int { muted ? 0 : min(volume, volumeLimit) }
    var shortcutsAvailable: Bool { state?.shortcutsAvailable ?? false }
    var micHotkeyAvailable: Bool { state?.micHotkeyAvailable ?? false }
    var mediaKeysAuthorized: Bool { uiAccessibilityTrusted || (state?.mediaKeysAuthorized ?? false) }
    var mediaKeysActive: Bool { uiMediaKeyTap.isRunning || (state?.mediaKeysActive ?? false) }
    var showOSD: Bool { state?.showOSD ?? true }
    var showMenuBarPercent: Bool { state?.showMenuBarPercent ?? false }
    var scrollOnIconEnabled: Bool { state?.scrollOnIconEnabled ?? true }
    var deviceUID: String? { currentOutputDevice?.uid ?? state?.deviceUID }
    var deviceName: String? { currentOutputDevice?.name ?? state?.deviceName }
    var transportLabel: String? { currentOutputDevice?.transportKind.displayLabel ?? state?.transportLabel }
    var isEngineConnected: Bool { xpcConnected || state != nil }
    var isControllable: Bool { currentOutputDevice?.isAutoControllable ?? (state?.isControllable ?? false) }
    var isEnabled: Bool { stateMatchesCurrentOutput ? (state?.enabled ?? false) : false }

    var isSoftwareOutputActive: Bool { phase == .active && isControllable && stateMatchesCurrentOutput }
    var isNativeHardwareOutput: Bool { !isControllable && (currentOutputDevice?.volumeControlAvailable == true) }
    var canControlCurrentOutput: Bool { isSoftwareOutputActive || isNativeHardwareOutput }
    var isPlayingOnLockedDisplay: Bool {
        isSoftwareOutputActive && (currentOutputDevice?.isRunningSomewhere == true)
    }

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

        let timer = Timer(timeInterval: 30.0, target: self, selector: #selector(pollFallback), userInfo: nil, repeats: true)
        timer.tolerance = 5.0
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        installSystemAudioListeners()
        refreshAllAudioDevices(force: true)
        connectXPC()
        syncUIMediaKeyTap()
    }

    func shutDown() {
        heartbeat?.invalidate()
        heartbeat = nil
        axPollTimer?.invalidate()
        axPollTimer = nil
        deviceListDebounceWorkItem?.cancel()
        deviceListDebounceWorkItem = nil
        trailingReconcileWorkItem?.cancel()
        trailingReconcileWorkItem = nil
        removeSystemAudioListeners()
        if uiMediaKeyTap.isRunning {
            sendMediaKeyLease(active: false)
        }
        uiMediaKeyTap.stop()
        xpcConnection?.invalidate()
        xpcConnection = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Authenticated XPC Client

    func reconnectXPC() {
        xpcConnection?.invalidate()
        xpcConnection = nil
        if xpcConnected { xpcConnected = false }
        connectXPC()
    }

    private func connectXPC() {
        if xpcConnection != nil { return }
        let conn = NSXPCConnection(machServiceName: VolumeIPC.xpcMachServiceName, options: [])
        conn.remoteObjectInterface = VolumeIPC.makeXPCInterface()
        let req = CodeSignInspector.peerCodeSigningRequirement(
            expectedBundleID: VolumeIPC.engineBundleID,
            matchingOwnIdentity: ownIdentity
        )
        conn.setCodeSigningRequirement(req)
        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.xpcConnection === conn else { return }
                self.xpcConnection = nil
                if self.xpcConnected { self.xpcConnected = false }
            }
        }
        conn.interruptionHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.xpcConnection === conn else { return }
                if self.xpcConnected { self.xpcConnected = false }
            }
        }
        conn.resume()
        xpcConnection = conn
        fetchStateViaXPC()
    }

    private func xpcProxy() -> DisplayVolumeEngineXPCProtocol? {
        if xpcConnection == nil { connectXPC() }
        return xpcConnection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                if self?.xpcConnected == true { self?.xpcConnected = false }
            }
        } as? DisplayVolumeEngineXPCProtocol
    }

    func fetchStateViaXPC() {
        xpcProxy()?.fetchState { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    if !self.xpcConnected { self.xpcConnected = true }
                    self.applyIncomingState(decoded)
                    if self.uiMediaKeyTap.isRunning {
                        self.sendMediaKeyLease(active: true)
                    }
                }
            }
        }
    }

    private func sendMediaKeyLease(active: Bool) {
        xpcProxy()?.setUIMediaKeysActive(active, clientInstanceID: clientInstanceID) { [weak self] data in
            Task { @MainActor in
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    self?.applyIncomingState(decoded)
                }
            }
        }
    }

    // MARK: - Device & Hardware Sync (Direct Compare-Before-Write — Zero Phantom @Published Emissions)

    func refreshIfStale(maxAge: TimeInterval = 0.12) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFullRefreshAt >= maxAge {
            refreshAllAudioDevices(force: true)
        }
    }

    /// Single-pass CoreAudio HAL snapshot refresh: enumerates devices once and preserves last list on transient HAL error.
    func refreshAllAudioDevices(force: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastFullRefreshAt < 0.12 { return }
        lastFullRefreshAt = now

        let snapshot = AudioDeviceCatalog.captureSnapshot()
        applyDeviceSnapshot(snapshot)
    }

    /// Internal testable entry point verifying zero phantom `objectWillChange` emissions on identical snapshots.
    func applyDeviceSnapshot(_ snapshot: AudioDeviceSnapshot) {
        var changed = false
        let previousOutUID = currentOutputDevice?.uid
        let previousInUID = currentInputDevice?.uid

        if snapshot.querySucceeded {
            if outputDevices != snapshot.outputDevices {
                outputDevices = snapshot.outputDevices
                changed = true
            }
            if inputDevices != snapshot.inputDevices {
                inputDevices = snapshot.inputDevices
                changed = true
            }
        }
        if currentOutputDevice != snapshot.defaultOutput {
            currentOutputDevice = snapshot.defaultOutput
            changed = true
        }
        if currentInputDevice != snapshot.defaultInput {
            currentInputDevice = snapshot.defaultInput
            changed = true
        }

        if previousOutUID != currentOutputDevice?.uid {
            clearOutputOptimisticState()
        }
        if previousInUID != currentInputDevice?.uid {
            isDraggingInput = false
            inputLockUntil = 0
        }

        installNativeOutputListeners(for: currentOutputDevice)
        installInputListeners(for: currentInputDevice)
        if syncNativeOutputHardwareState(force: false) { changed = true }
        if syncInputHardwareState(force: false) { changed = true }
        if changed {
            onChange?()
        }
    }

    private func clearOutputOptimisticState() {
        isDraggingVolume = false
        isDraggingLimit = false
        isDraggingNativeOut = false
        volumeLockUntil = 0
        limitLockUntil = 0
        nativeOutLockUntil = 0
        if optimisticVolume != nil { optimisticVolume = nil }
        if optimisticLimit != nil { optimisticLimit = nil }
        if optimisticMuted != nil { optimisticMuted = nil }
    }

    func refreshOutputDevices() {
        var changed = false
        let previousOutUID = currentOutputDevice?.uid
        let latestList = OutputDeviceCatalog.allOutputDevices()
        let latestDef = OutputDeviceCatalog.currentDefault()
        if !latestList.isEmpty && outputDevices != latestList {
            outputDevices = latestList
            changed = true
        }
        if currentOutputDevice != latestDef {
            currentOutputDevice = latestDef
            changed = true
        }
        if previousOutUID != currentOutputDevice?.uid {
            clearOutputOptimisticState()
        }
        installNativeOutputListeners(for: currentOutputDevice)
        if syncNativeOutputHardwareState(force: false) { changed = true }
        if changed {
            onChange?()
        }
    }

    func refreshInputDevices() {
        var changed = false
        let previousInUID = currentInputDevice?.uid
        let latestList = InputDeviceCatalog.allInputDevices()
        let latestDef = InputDeviceCatalog.currentDefault()
        if !latestList.isEmpty && inputDevices != latestList {
            inputDevices = latestList
            changed = true
        }
        if currentInputDevice != latestDef {
            currentInputDevice = latestDef
            changed = true
        }
        if previousInUID != currentInputDevice?.uid {
            isDraggingInput = false
            inputLockUntil = 0
        }
        installInputListeners(for: currentInputDevice)
        if syncInputHardwareState(force: false) { changed = true }
        if changed {
            onChange?()
        }
    }

    func refreshAccessibilityState() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        if uiAccessibilityTrusted != trusted {
            uiAccessibilityTrusted = trusted
            onChange?()
        }
        syncUIMediaKeyTap()
    }

    func selectOutputDevice(uid: String) {
        let switched: Bool
        if let cached = outputDevices.first(where: { $0.uid == uid }) {
            switched = OutputDeviceCatalog.setDefaultOutput(deviceID: cached.id, expectedUID: cached.uid)
        } else {
            switched = OutputDeviceCatalog.setDefaultOutput(uid: uid)
        }
        if switched {
            clearOutputOptimisticState()
            refreshOutputDevices()
        }
    }

    func selectInputDevice(uid: String) {
        let switched: Bool
        if let cached = inputDevices.first(where: { $0.uid == uid }) {
            switched = InputDeviceCatalog.setDefaultInput(deviceID: cached.id, expectedUID: cached.uid)
        } else {
            switched = InputDeviceCatalog.setDefaultInput(uid: uid)
        }
        if switched {
            isDraggingInput = false
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
        let map = dev.outputControlMap
        if let scalar = AudioHardwareControl.readScalarVolume(
            deviceID: dev.id,
            scope: kAudioDevicePropertyScopeOutput,
            elements: map.volumeElements
        ) {
            let pct = Int((scalar * 100.0).rounded())
            if nativeOutputVolume != pct {
                nativeOutputVolume = pct
                changed = true
            }
        }
        if map.hasFullHardwareMute,
           let hwMuted = AudioHardwareControl.readMute(
               deviceID: dev.id,
               scope: kAudioDevicePropertyScopeOutput,
               elements: map.muteElements
           ) {
            if nativeOutputMuted != hwMuted {
                nativeOutputMuted = hwMuted
                changed = true
            }
        } else {
            let derived = (nativeOutputVolume == 0)
            if nativeOutputMuted != derived {
                nativeOutputMuted = derived
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    private func syncInputHardwareState(force: Bool) -> Bool {
        guard let mic = currentInputDevice else {
            var changed = false
            if inputVolume != 0 { inputVolume = 0; changed = true }
            if inputMuted != false { inputMuted = false; changed = true }
            if inputVolumeWritable != false { inputVolumeWritable = false; changed = true }
            if inputMuteSupported != false { inputMuteSupported = false; changed = true }
            if inputUsesSoftMute != false { inputUsesSoftMute = false; changed = true }
            if inputStatusReadable != true { inputStatusReadable = true; changed = true }
            return changed
        }
        // Check drag/lock window BEFORE reading HAL so continuous drags don't pay redundant HAL reads.
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (!isDraggingInput && now >= inputLockUntil) else { return false }

        let status = MicrophoneControl.readStatus(for: mic)
        return applyInputStatus(status)
    }

    @discardableResult
    private func applyInputStatus(_ status: MicrophoneControl.Status) -> Bool {
        var changed = false
        if inputVolumeWritable != status.volumeWritable { inputVolumeWritable = status.volumeWritable; changed = true }
        if inputMuteSupported != status.muteSupported { inputMuteSupported = status.muteSupported; changed = true }
        if inputUsesSoftMute != status.usesSoftMute { inputUsesSoftMute = status.usesSoftMute; changed = true }
        if inputStatusReadable != status.readSucceeded { inputStatusReadable = status.readSucceeded; changed = true }
        if status.readSucceeded {
            if inputVolume != status.volumePercent { inputVolume = status.volumePercent; changed = true }
            if inputMuted != status.muted { inputMuted = status.muted; changed = true }
        }
        return changed
    }

    private func scheduleTrailingReconciliation(after delay: TimeInterval = 0.32) {
        trailingReconcileWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailingReconcileWorkItem = nil
            var changed = false
            if self.syncNativeOutputHardwareState(force: true) { changed = true }
            if self.syncInputHardwareState(force: true) { changed = true }
            if !self.isDraggingVolume && !self.isDraggingLimit {
                self.fetchStateViaXPC()
            }
            if changed { self.onChange?() }
        }
        trailingReconcileWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - CoreAudio Property Listeners (Unified ChannelControlMap Coverage)

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
        guard targetID != kAudioObjectUnknown, let device else { return }
        observedNativeOutID = targetID

        let elems = device.outputControlMap.observedElements
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element in elems {
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
        guard targetID != kAudioObjectUnknown, let device else { return }
        observedInputID = targetID

        let elems = device.inputControlMap.observedElements
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element in elems {
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

    // MARK: - Engine State Sync

    @objc private func handleStateNotification(_ notification: Notification) {
        if let latest = VolumeIPC.readCachedSnapshot(from: notification) {
            applyIncomingState(latest)
        }
    }

    func applyIncomingState(_ latest: VolumeState?) {
        let now = ProcessInfo.processInfo.systemUptime
        let isFreshExternalHardwareTrigger: Bool
        if let latest, latest.lastTriggerNonce != lastHandledTriggerNonce {
            lastHandledTriggerNonce = latest.lastTriggerNonce
            isFreshExternalHardwareTrigger = latest.lastTriggerSource == .mediaKey
                || latest.lastTriggerSource == .hotkey
                || latest.lastTriggerSource == .scroll
        } else {
            isFreshExternalHardwareTrigger = false
        }

        if isFreshExternalHardwareTrigger || (!isDraggingVolume && now >= volumeLockUntil) {
            if optimisticVolume != nil { optimisticVolume = nil }
            if optimisticMuted != nil { optimisticMuted = nil }
        }
        if !isDraggingLimit && now >= limitLockUntil {
            if optimisticLimit != nil { optimisticLimit = nil }
        }

        if state != latest {
            state = latest
            updateMediaKeyInterceptFlagOnly()
            onChange?()
        }
    }

    func refreshFromEngine() {
        if let cached = VolumeIPC.readCachedSnapshot() {
            applyIncomingState(cached)
        }
        fetchStateViaXPC()
    }

    @objc private func pollFallback() {
        if !xpcConnected {
            fetchStateViaXPC()
        }
        if !uiAccessibilityTrusted {
            refreshAccessibilityState()
        }
    }

    // MARK: - Media Keys & Scroll

    private func updateMediaKeyInterceptFlagOnly() {
        let shouldIntercept = isEnabled && (phase == .active || phase == .checking) && isControllable && stateMatchesCurrentOutput
        uiMediaKeyTap.shouldIntercept = uiMediaKeyTap.isRunning && shouldIntercept
    }

    private func syncUIMediaKeyTap() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        if uiAccessibilityTrusted != trusted {
            uiAccessibilityTrusted = trusted
        }
        if trusted {
            axPollTimer?.invalidate()
            axPollTimer = nil
            if !uiMediaKeyTap.isRunning {
                if uiMediaKeyTap.start() {
                    sendMediaKeyLease(active: true)
                }
            }
            updateMediaKeyInterceptFlagOnly()
        } else {
            if uiMediaKeyTap.isRunning {
                uiMediaKeyTap.stop()
                sendMediaKeyLease(active: false)
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
        guard (phase == .active || phase == .checking), let uid = deviceUID else { return }
        let replyHandler: (Data?) -> Void = { [weak self] data in
            Task { @MainActor in
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    self?.applyIncomingState(decoded)
                }
            }
        }
        switch action {
        case .volumeUp(let fine):
            xpcProxy()?.stepVolume(fine ? 1 : 5, deviceUID: uid, source: VolumeState.TriggerSource.mediaKey.rawValue, withReply: replyHandler)
        case .volumeDown(let fine):
            xpcProxy()?.stepVolume(fine ? -1 : -5, deviceUID: uid, source: VolumeState.TriggerSource.mediaKey.rawValue, withReply: replyHandler)
        case .toggleMute:
            xpcProxy()?.toggleOutputMute(deviceUID: uid, source: VolumeState.TriggerSource.mediaKey.rawValue, withReply: replyHandler)
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

        if isSoftwareOutputActive, let uid = deviceUID {
            xpcProxy()?.stepVolume(steps * 2, deviceUID: uid, source: VolumeState.TriggerSource.scroll.rawValue) { [weak self] data in
                Task { @MainActor in
                    if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                        self?.applyIncomingState(decoded)
                    }
                }
            }
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

    // MARK: - Output Mutations (Software via XPC + Native Hardware via HAL)

    func enable() {
        UserDefaults.standard.set(false, forKey: "UserStoppedEngine")
        if !xpcConnected && !EngineProvisioner.isEngineProcessRunning() {
            DispatchQueue.global(qos: .userInitiated).async {
                EngineProvisioner.ensureInstalledAndRunning()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.reconnectXPC()
                    self.xpcProxy()?.setEnabled(true) { [weak self] data in
                        Task { @MainActor in
                            if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                                self?.applyIncomingState(decoded)
                            }
                        }
                    }
                }
            }
            return
        }
        xpcProxy()?.setEnabled(true) { [weak self] data in
            Task { @MainActor in
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    self?.applyIncomingState(decoded)
                }
            }
        }
    }

    func disable() {
        xpcProxy()?.setEnabled(false) { [weak self] data in
            Task { @MainActor in
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    self?.applyIncomingState(decoded)
                }
            }
        }
    }

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
        guard let uid = deviceUID else { return }
        let clamped = VolumeMath.clampedVolume(percent, limit: volumeLimit)
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingVolume = isDragging
        volumeLockUntil = now + 0.30
        if clamped > 0 {
            if optimisticVolume != clamped { optimisticVolume = clamped }
            if optimisticMuted != false { optimisticMuted = false }
        } else {
            if optimisticMuted != true { optimisticMuted = true }
        }
        onChange?()

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastVolumeIPCSentAt, minInterval: 0.025, isDragging: isDragging) {
            lastVolumeIPCSentAt = now
            xpcProxy()?.setVolume(clamped, deviceUID: uid, isDragging: isDragging, source: VolumeState.TriggerSource.slider.rawValue) { [weak self] data in
                Task { @MainActor in
                    if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                        self?.applyIncomingState(decoded)
                    }
                }
            }
        }
        if !isDragging {
            scheduleTrailingReconciliation()
        }
    }

    func setVolumeLimit(_ percent: Int, isDragging: Bool = false) {
        guard let uid = deviceUID else { return }
        let clamped = min(100, max(1, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingLimit = isDragging
        limitLockUntil = now + 0.30
        if optimisticLimit != clamped { optimisticLimit = clamped }
        if let v = optimisticVolume, v > clamped {
            optimisticVolume = clamped
        }
        onChange?()

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastLimitIPCSentAt, minInterval: 0.025, isDragging: isDragging) {
            lastLimitIPCSentAt = now
            xpcProxy()?.setLimit(clamped, deviceUID: uid, isDragging: isDragging) { [weak self] data in
                Task { @MainActor in
                    if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                        self?.applyIncomingState(decoded)
                    }
                }
            }
        }
        if !isDragging {
            scheduleTrailingReconciliation()
        }
    }

    func toggleMute() {
        guard let uid = deviceUID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        volumeLockUntil = now + 0.25
        let target = !muted
        if optimisticMuted != target { optimisticMuted = target }
        onChange?()
        xpcProxy()?.toggleOutputMute(deviceUID: uid, source: VolumeState.TriggerSource.slider.rawValue) { [weak self] data in
            Task { @MainActor in
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    self?.applyIncomingState(decoded)
                }
            }
        }
    }

    func setNativeOutputVolume(_ percent: Int, isDragging: Bool = false) {
        guard let dev = currentOutputDevice, dev.volumeControlAvailable else { return }
        let clamped = min(100, max(0, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingNativeOut = isDragging
        nativeOutLockUntil = now + 0.25
        if nativeOutputVolume != clamped { nativeOutputVolume = clamped }
        let wantMuted = (clamped == 0)
        if nativeOutputMuted != wantMuted { nativeOutputMuted = wantMuted }

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastNativeOutHALSentAt, minInterval: 0.020, isDragging: isDragging) {
            lastNativeOutHALSentAt = now
            let map = dev.outputControlMap
            _ = AudioHardwareControl.writeScalarVolume(
                deviceID: dev.id,
                scope: kAudioDevicePropertyScopeOutput,
                elements: map.volumeElements,
                fraction: Float(clamped) / 100.0
            )
            if map.hasFullHardwareMute {
                _ = AudioHardwareControl.writeMute(
                    deviceID: dev.id,
                    scope: kAudioDevicePropertyScopeOutput,
                    elements: map.muteElements,
                    muted: clamped == 0
                )
            }
        }
        onChange?()
        if !isDragging {
            scheduleTrailingReconciliation()
        }
    }

    func toggleNativeOutputMute() {
        guard let dev = currentOutputDevice, dev.volumeControlAvailable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        nativeOutLockUntil = now + 0.25
        let targetMuted = !nativeOutputMuted
        if nativeOutputMuted != targetMuted { nativeOutputMuted = targetMuted }

        let map = dev.outputControlMap
        if map.hasFullHardwareMute {
            _ = AudioHardwareControl.writeMute(
                deviceID: dev.id,
                scope: kAudioDevicePropertyScopeOutput,
                elements: map.muteElements,
                muted: targetMuted
            )
            if !targetMuted && nativeOutputVolume == 0 {
                nativeOutputVolume = 25
                _ = AudioHardwareControl.writeScalarVolume(
                    deviceID: dev.id,
                    scope: kAudioDevicePropertyScopeOutput,
                    elements: map.volumeElements,
                    fraction: 0.25
                )
            }
        } else {
            let applied = targetMuted ? 0 : max(10, nativeOutputVolume)
            _ = AudioHardwareControl.writeScalarVolume(
                deviceID: dev.id,
                scope: kAudioDevicePropertyScopeOutput,
                elements: map.volumeElements,
                fraction: Float(applied) / 100.0
            )
        }
        onChange?()
        scheduleTrailingReconciliation()
    }

    // MARK: - Input / Microphone Mutations (Serialized Through Engine XPC Single-Writer)

    func setInputVolume(_ percent: Int, isDragging: Bool = false) {
        guard let mic = currentInputDevice, mic.inputVolumeControlAvailable else { return }
        let clamped = min(100, max(0, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingInput = isDragging
        inputLockUntil = now + 0.25
        if inputVolume != clamped { inputVolume = clamped }
        if clamped == 0 && !mic.inputMuteControlAvailable && !inputMuted {
            inputMuted = true
        }
        onChange?()

        if DispatchThrottleMath.shouldEmit(now: now, lastSentAt: lastInputHALSentAt, minInterval: 0.020, isDragging: isDragging) {
            lastInputHALSentAt = now
            let engineExplicitlyStopped = UserDefaults.standard.bool(forKey: "UserStoppedEngine")
            if !engineExplicitlyStopped, let proxy = xpcProxy() {
                // Single-writer invariant: always route mic writes through Engine XPC whenever Engine is enabled
                // (launchd MachServices wakes Engine on demand, preventing any UI/Engine dual-write overlap).
                proxy.setMicVolume(clamped, deviceUID: mic.uid, isDragging: isDragging) { [weak self] ok, data in
                    Task { @MainActor in
                        guard let self else { return }
                        if ok, let data, let status = try? JSONDecoder().decode(MicrophoneControl.Status.self, from: data), !self.isDraggingInput {
                            if self.applyInputStatus(status) { self.onChange?() }
                        }
                    }
                }
            } else if engineExplicitlyStopped && !EngineProvisioner.isEngineProcessRunning() {
                _ = MicrophoneControl.applyVolume(clamped, for: mic, persistPreMute: !isDragging, clearMuteIfPositive: false)
            }
        }
        if !isDragging {
            scheduleTrailingReconciliation()
        }
    }

    func toggleInputMute(showOSD: Bool = false) {
        guard let mic = currentInputDevice, mic.inputMuteSupported else { return }
        let now = ProcessInfo.processInfo.systemUptime
        inputLockUntil = now + 0.25
        let engineExplicitlyStopped = UserDefaults.standard.bool(forKey: "UserStoppedEngine")
        if !engineExplicitlyStopped, let proxy = xpcProxy() {
            proxy.toggleMicMute(deviceUID: mic.uid, showOSD: showOSD) { [weak self] ok, data in
                Task { @MainActor in
                    guard let self else { return }
                    if ok, let data, let status = try? JSONDecoder().decode(MicrophoneControl.Status.self, from: data) {
                        if self.applyInputStatus(status) { self.onChange?() }
                    } else {
                        _ = self.syncInputHardwareState(force: true)
                        self.onChange?()
                    }
                }
            }
        } else if engineExplicitlyStopped && !EngineProvisioner.isEngineProcessRunning(),
                  let updated = MicrophoneControl.toggleMute(for: mic) {
            if applyInputStatus(updated) { onChange?() }
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

    func setShowOSD(_ flag: Bool) { sendPreference("showOSD", flag: flag) }
    func setShowMenuBarPercent(_ flag: Bool) { sendPreference("showMenuBarPercent", flag: flag) }
    func setScrollOnIcon(_ flag: Bool) { sendPreference("scrollOnIcon", flag: flag) }

    private func sendPreference(_ key: String, flag: Bool) {
        xpcProxy()?.setPreference(key, flag: flag) { [weak self] data in
            Task { @MainActor in
                if let data, let decoded = VolumeIPC.decodeValidatedState(data) {
                    self?.applyIncomingState(decoded)
                }
            }
        }
    }
}

/// Transactional, lock-protected, signature-verified LaunchAgent provisioner with automatic rollback.
enum EngineProvisioner {
    static let supportDir = VolumeIPC.directory
    static let installedEngineURL = supportDir.appendingPathComponent("DisplayVolumeEngine.app", isDirectory: true)
    static let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    static let plistURL = launchAgentDir.appendingPathComponent("\(VolumeIPC.engineBundleID).plist")
    static let legacyPlistURL = launchAgentDir.appendingPathComponent("\(VolumeIPC.legacyEngineBundleID).plist")

    static func ensureInstalledAndRunning() {
        do {
            try InstallTransactionLock.withExclusiveLock {
                cleanLegacyEngineIfPresent()

                guard verifyTrustedDirectory(supportDir),
                      let embeddedURL = embeddedEngineURL() else {
                    return
                }

                // Verify embedded Engine full bundle signature + Team ID match before trusting it.
                let ownIdentity = CodeSignInspector.currentProcessIdentity()
                guard verifyEngineBundle(at: embeddedURL, matchingTeamOf: ownIdentity) else {
                    NSLog("DisplayVolume: embedded DisplayVolumeEngine failed signature verification")
                    return
                }

                let embeddedBuild = bundleBuildNumber(at: embeddedURL)
                let installedBuild = bundleBuildNumber(at: installedEngineURL)

                // Monotonic version policy: never downgrade a newer installed Engine on ordinary startup.
                if installedBuild > embeddedBuild && verifyEngineBundle(at: installedEngineURL, matchingTeamOf: ownIdentity) {
                    ensureLaunchAgentPlist()
                    if !isServiceLoaded() {
                        bootstrapLaunchAgent()
                    }
                    return
                }

                let needsInstall = shouldUpdateInstalledEngine(
                    embedded: embeddedURL,
                    installed: installedEngineURL,
                    ownIdentity: ownIdentity
                )

                if needsInstall {
                    try performTransactionalEngineSwap(embeddedURL: embeddedURL, ownIdentity: ownIdentity)
                } else {
                    ensureLaunchAgentPlist()
                    if !isServiceLoaded() {
                        bootstrapLaunchAgent()
                    }
                }
            }
        } catch {
            NSLog("DisplayVolume EngineProvisioner failed: %@", error.localizedDescription)
        }
    }

    static func uninstallAndStopEngine() {
        try? InstallTransactionLock.withExclusiveLock {
            _ = bootOut(label: VolumeIPC.engineBundleID, plist: plistURL)
            terminateProcess(bundleIdentifier: VolumeIPC.engineBundleID)
            try? FileManager.default.removeItem(at: plistURL)
            try? FileManager.default.removeItem(at: installedEngineURL)
        }
    }

    private static func performTransactionalEngineSwap(
        embeddedURL: URL,
        ownIdentity: CodeSignInspector.SigningIdentity?
    ) throws {
        let fm = FileManager.default
        let stagingURL = supportDir.appendingPathComponent(".DisplayVolumeEngine-staging-\(UUID().uuidString).app", isDirectory: true)
        let backupName = ".DisplayVolumeEngine-previous-\(UUID().uuidString).app"
        let backupURL = supportDir.appendingPathComponent(backupName, isDirectory: true)
        defer { try? fm.removeItem(at: stagingURL) }

        // 1. Stage full copy first (old Engine keeps running undisturbed until copy & verification succeed).
        try fm.copyItem(at: embeddedURL, to: stagingURL)
        guard verifyEngineBundle(at: stagingURL, matchingTeamOf: ownIdentity) else {
            throw OTAValidationError.signatureVerificationFailed("Staged DisplayVolumeEngine failed strict verification")
        }

        // 2. Stop old Engine only after new bundle is staged and verified.
        _ = bootOut(label: VolumeIPC.engineBundleID, plist: plistURL)
        terminateProcess(bundleIdentifier: VolumeIPC.engineBundleID)

        // 3. Atomic swap preserving previous backup via `.withoutDeletingBackupItem` so rollback actually works.
        let hadPrevious = fm.fileExists(atPath: installedEngineURL.path)
        if hadPrevious {
            _ = try fm.replaceItemAt(
                installedEngineURL,
                withItemAt: stagingURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
        } else {
            try fm.moveItem(at: stagingURL, to: installedEngineURL)
        }

        ensureLaunchAgentPlist()
        let startedOK = bootstrapLaunchAgent()
        if startedOK {
            try? fm.removeItem(at: backupURL)
        } else if hadPrevious && fm.fileExists(atPath: backupURL.path) {
            // Roll back to previous working Engine on bootstrap failure.
            NSLog("DisplayVolume: new Engine bootstrap failed; rolling back to previous Engine")
            _ = try? fm.replaceItemAt(installedEngineURL, withItemAt: backupURL, backupItemName: nil, options: [])
            ensureLaunchAgentPlist()
            _ = bootstrapLaunchAgent()
        }
    }

    static func isEngineProcessRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: VolumeIPC.engineBundleID).isEmpty
    }

    private static func verifyTrustedDirectory(_ dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var st = stat()
        guard lstat(dir.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid() else {
            return false
        }
        return true
    }

    private static func verifyEngineBundle(at url: URL, matchingTeamOf ownIdentity: CodeSignInspector.SigningIdentity?) -> Bool {
        guard let sign = CodeSignInspector.inspectBundle(at: url, verifyStrict: true),
              sign.identifier == VolumeIPC.engineBundleID else {
            return false
        }
        if let ownTeam = ownIdentity?.teamIdentifier, !ownTeam.isEmpty {
            return sign.teamIdentifier == ownTeam
        }
        return true
    }

    private static func bundleBuildNumber(at url: URL) -> Int {
        Int(Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    private static func embeddedEngineURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/DisplayVolumeEngine.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func shouldUpdateInstalledEngine(
        embedded: URL,
        installed: URL,
        ownIdentity: CodeSignInspector.SigningIdentity?
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: installed.path),
              verifyEngineBundle(at: installed, matchingTeamOf: ownIdentity) else {
            return true
        }
        if bundleBuildNumber(at: embedded) != bundleBuildNumber(at: installed) {
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
            "MachServices": [VolumeIPC.xpcMachServiceName: true],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5
        ]
        try? FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    private static func cleanLegacyEngineIfPresent() {
        if FileManager.default.fileExists(atPath: legacyPlistURL.path) {
            _ = bootOut(label: VolumeIPC.legacyEngineBundleID, plist: legacyPlistURL)
            try? FileManager.default.removeItem(at: legacyPlistURL)
        }
        terminateProcess(bundleIdentifier: VolumeIPC.legacyEngineBundleID)
        terminateProcess(bundleIdentifier: "local.kahlil.RedmiVolume")
    }

    private static func isServiceLoaded() -> Bool {
        let domain = "gui/\(getuid())/\(VolumeIPC.engineBundleID)"
        return runLaunchctl(["print", domain]) == 0
    }

    @discardableResult
    private static func bootOut(label: String, plist: URL) -> Bool {
        let domain = "gui/\(getuid())"
        let s1 = runLaunchctl(["bootout", "\(domain)/\(label)"])
        let s2 = runLaunchctl(["bootout", domain, plist.path])
        return s1 == 0 || s2 == 0
    }

    @discardableResult
    private static func bootstrapLaunchAgent() -> Bool {
        let domain = "gui/\(getuid())"
        let status = runLaunchctl(["bootstrap", domain, plistURL.path])
        if status == 0 { return true }
        return runLaunchctl(["kickstart", "-k", "\(domain)/\(VolumeIPC.engineBundleID)"]) == 0
    }

    private static func terminateProcess(bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            if app.processIdentifier != getpid() {
                app.terminate()
            }
        }
    }

    /// Safely runs `/bin/launchctl` checking `task.run()` errors before waiting or reading `terminationStatus`.
    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("DisplayVolume launchctl spawn failed: %@", error.localizedDescription)
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// Separate icon-raster key (wave tier 0..3) from label/tooltip key so 51%->52% drags or mic mute never re-render NSImage.
    private struct StatusIconKey: Equatable {
        let waveTier: Int
        let muted: Bool
        let active: Bool
    }

    private struct StatusLabelKey: Equatable {
        let volume: Int
        let muted: Bool
        let active: Bool
        let showPercent: Bool
        let inputMuted: Bool
    }

    private let model = VolumeController()
    private let updater = AppUpdater()
    private let log = Logger(subsystem: VolumeIPC.suiteName, category: "DisplayVolumeUI")
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var lastIconKey: StatusIconKey?
    private var lastLabelKey: StatusLabelKey?
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
            guard let state = VolumeIPC.readCachedSnapshot() else {
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
                print("  Input volume: \(micStatus.volumePercent)% (writable=\(micStatus.volumeWritable)), muted=\(micStatus.muted) (muteSupported=\(micStatus.muteSupported), softMute=\(micStatus.usesSoftMute), readable=\(micStatus.readSucceeded))")
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
                updater: updater,
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
        model.refreshFromEngine()
        updateStatusItemAppearance()
        updater.startScheduledChecks()

        // Provision / upgrade embedded LaunchAgent engine off the main thread unless user explicitly stopped it.
        let userStopped = UserDefaults.standard.bool(forKey: "UserStoppedEngine")
        if !userStopped {
            DispatchQueue.global(qos: .userInitiated).async {
                EngineProvisioner.ensureInstalledAndRunning()
                DispatchQueue.main.async { [weak self] in
                    self?.model.reconnectXPC()
                }
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

        if CommandLine.arguments.contains("--open-popover") || (model.isControllable && model.phase != .active && !userStopped) {
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
        updater.stopScheduledChecks()
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
            model.refreshFromEngine()
            model.refreshAllAudioDevices(force: true)
            model.refreshAccessibilityState()
            showPopover()
        }
    }

    private func showQuickContextMenu(_ button: NSStatusBarButton) {
        closePopover()
        model.refreshAllAudioDevices(force: true)

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
        UserDefaults.standard.set(true, forKey: "UserStoppedEngine")
        DispatchQueue.global(qos: .userInitiated).async {
            EngineProvisioner.uninstallAndStopEngine()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
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

    private static func iconWaveTier(volume: Int, muted: Bool, active: Bool) -> Int {
        guard active else { return 2 }
        if muted || volume <= 0 { return 0 }
        if volume < 34 { return 1 }
        if volume < 68 { return 2 }
        return 3
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let outActive = model.canControlCurrentOutput
        let vol = model.effectiveOutputVolume
        let outMuted = model.effectiveOutputMuted

        let iconKey = StatusIconKey(
            waveTier: Self.iconWaveTier(volume: vol, muted: outMuted, active: outActive),
            muted: outMuted,
            active: outActive
        )
        if iconKey != lastIconKey {
            lastIconKey = iconKey
            button.image = MenuBarIconRenderer.makeIcon(
                volume: vol,
                muted: outMuted,
                active: outActive
            )
        }

        let labelKey = StatusLabelKey(
            volume: vol,
            muted: outMuted,
            active: outActive,
            showPercent: model.showMenuBarPercent,
            inputMuted: model.inputMuted
        )
        guard labelKey != lastLabelKey else { return }
        lastLabelKey = labelKey

        let baseLabel = outActive
            ? (labelKey.muted ? L10n.mutedLabel : "\(L10n.appName) \(labelKey.volume)%")
            : L10n.appName
        let fullLabel = labelKey.inputMuted
            ? "\(baseLabel) · \(L10n.micMutedOSDLabel)"
            : baseLabel

        button.imagePosition = labelKey.showPercent && outActive ? .imageLeading : .imageOnly
        if labelKey.showPercent && outActive {
            let text = labelKey.muted ? L10n.mutedLabel : "\(labelKey.volume)%"
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
    let coldStart = CFAbsoluteTimeGetCurrent()
    let coldSnap = AudioDeviceCatalog.captureSnapshot()
    let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000.0

    let iterations = 6
    var snapshotTimes: [Double] = []
    var ipcTimes: [Double] = []

    for _ in 0..<iterations {
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = AudioDeviceCatalog.captureSnapshot()
        snapshotTimes.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)

        let t1 = CFAbsoluteTimeGetCurrent()
        _ = VolumeIPC.readCachedSnapshot()
        ipcTimes.append((CFAbsoluteTimeGetCurrent() - t1) * 1000.0)
    }

    let snapAvg = snapshotTimes.reduce(0, +) / Double(iterations)
    let snapMax = snapshotTimes.max() ?? 0
    let ipcAvg = ipcTimes.reduce(0, +) / Double(iterations)
    print(String(format: "BENCH cold HAL snapshot         = %.2f ms (queryOK=%@)", coldMs, coldSnap.querySucceeded ? "true" : "false"))
    print(String(format: "BENCH warm HAL snapshot avg/max = %.2f / %.2f ms (budget <= 50.00 ms)", snapAvg, snapMax))
    print(String(format: "BENCH VolumeIPC cached read avg = %.2f ms (budget <= 10.00 ms)", ipcAvg))
    let pass = coldSnap.querySucceeded && snapAvg <= 50.0 && ipcAvg <= 10.0
    print(pass ? "PASS latency budget" : "FAIL latency budget exceeded")
    exit(pass ? 0 : 1)
}

@MainActor
private func runSelfTestSuite() {
    // 1. Core volume & overflow math
    let clamped1 = VolumeMath.clampedVolume(95, limit: 80) == 80
    let clamped2 = VolumeMath.clampedVolume(-5, limit: 80) == 0
    let step1 = VolumeMath.applyStep(currentVolume: 60, limit: 80, muted: false, delta: 5) == (65, false)
    let step2 = VolumeMath.applyStep(currentVolume: 78, limit: 80, muted: false, delta: 5) == (80, false)
    let step3 = VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: false, delta: -5) == (3, true)
    let step4 = VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: true, delta: 5) == (3, false)
    let step5 = VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: -5) == (40, true)
    let stepOverflowPos = VolumeMath.applyStep(currentVolume: 50, limit: 80, muted: false, delta: Int.max) == (80, false)
    let stepOverflowNeg = VolumeMath.applyStep(currentVolume: 50, limit: 80, muted: false, delta: Int.min) == (50, true)
    let mic1 = InputMuteMath.planSoftMute(currentPercent: 85, savedBeforeMute: nil, targetMuted: true)
        == .init(appliedPercent: 0, updatedSavedVolume: 85)
    let mic2 = InputMuteMath.planSoftMute(currentPercent: 0, savedBeforeMute: 85, targetMuted: false)
        == .init(appliedPercent: 85, updatedSavedVolume: 85)

    // 2. Verify Combine objectWillChange produces ZERO phantom emissions on identical state/snapshot!
    let ctrl = VolumeController()
    let snap = AudioDeviceSnapshot(outputDevices: [], inputDevices: [], defaultOutput: nil, defaultInput: nil, querySucceeded: true)
    ctrl.applyDeviceSnapshot(snap)
    var emissions = 0
    let cancellable = ctrl.objectWillChange.sink { emissions += 1 }
    ctrl.applyDeviceSnapshot(snap)
    ctrl.applyIncomingState(ctrl.state)
    cancellable.cancel()
    let zeroPhantomRedraws = (emissions == 0)

    let ok = clamped1 && clamped2 && step1 && step2 && step3 && step4 && step5
        && stepOverflowPos && stepOverflowNeg && mic1 && mic2 && zeroPhantomRedraws
    print(ok ? "PASS app volume, overflow, microphone & zero-phantom-publish tests" : "FAIL self-test (phantom emissions=\(emissions))")
    exit(ok ? 0 : 1)
}
