import AppKit
import CoreAudio
import Foundation

@MainActor
private final class VolumeEngine: NSObject, NSApplicationDelegate, NSXPCListenerDelegate {
    private let preferences = UserDefaults(suiteName: VolumeIPC.suiteName)!
    private let osd = VolumeOSD()
    private let routeQueue = DispatchQueue(label: "com.hazelkahlil.DisplayVolume.AudioRoute", qos: .userInitiated)
    private let engineInstanceID = UUID().uuidString
    private let engineBuild: Int = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    private let ownIdentity = CodeSignInspector.currentProcessIdentity()

    private var xpcListener: NSXPCListener?
    private var activeMediaKeyClients: Set<String> = []
    private var connectionClientMap: [ObjectIdentifier: String] = [:]

    private var device: AudioDeviceInfo? = OutputDeviceCatalog.currentDefault()
    private var phase = VolumeState.Phase.idle
    private var route: AudioRoute?
    private var routeGeneration: UInt64 = 0
    private var inFlightRouteGeneration: UInt64?
    private var unsupportedFormatDeviceUID: String?
    private var consecutiveRouteFailures = 0
    private var profiles: [String: DeviceVolumeProfile] = [:]

    private var volume: Int = 50
    private var limit: Int = 100
    private var muted: Bool = false
    private var enabled: Bool = true
    private var verifiedCapture: Bool = false
    private var showOSD: Bool = true
    private var showMenuBarPercent: Bool = false
    private var scrollOnIconEnabled: Bool = true

    private var outputHotkeysAvailable = false
    private var micHotkeyAvailable = false
    private var cachedAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted
    private var mediaKeysActive = false
    private var message: String?
    private var lastTriggerSource: VolumeState.TriggerSource?
    private var lastTriggerNonce: UInt64 = 0
    private var stateSequence: UInt64 = 0

    private var checkingTimer: Timer?
    private var watchdogTimer: Timer?
    private var accessibilityPollTimer: Timer?
    private var persistWorkItem: DispatchWorkItem?
    private var topologyDebounceWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?

    private var systemListenersInstalled = false
    private var observedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var deviceRunningListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var devicesListListener: AudioObjectPropertyListenerBlock?
    private var workspaceObservers: [NSObjectProtocol] = []

    private var systemSleeping = false
    private var screensSleeping = false
    private var retryAfter: TimeInterval = 0
    private var runningWithZeroSignalSince: TimeInterval?
    private var callbackCount: UInt32 = 0
    private var renderedCallbackCount: UInt32 = 0
    private var lastCallbackTime: TimeInterval = 0
    private var lastPublishedState: VolumeState?

    private var uiHandlesMediaKeys: Bool { !activeMediaKeyClients.isEmpty }
    private var isAsleepForCurrentDevice: Bool {
        if systemSleeping { return true }
        if screensSleeping && device?.transportKind.isExternalDisplayOrDigital == true { return true }
        return false
    }

    private lazy var mediaKeyTap = MediaKeyTap { [weak self] action in
        self?.handleMediaKey(action)
    }

    private lazy var hotkeys = Hotkeys { [weak self] key in
        guard let self else { return }
        if key == 4 {
            _ = self.toggleDefaultMicMute(expectedUID: nil, showHUD: true)
            return
        }
        guard self.phase == .active || self.phase == .checking else { return }
        switch key {
        case 1: self.applyStep(5, source: .hotkey)
        case 2: self.applyStep(-5, source: .hotkey)
        case 3: self.toggleMute(source: .hotkey)
        default: break
        }
    }

    override init() {
        super.init()
        loadAndMigratePreferences()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startXPCListener()
        installWorkspaceObservers()
        installSystemAudioListeners()
        micHotkeyAvailable = hotkeys.registerMicMute()

        cachedAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted
        if cachedAccessibilityTrusted {
            _ = mediaKeyTap.start()
            mediaKeysActive = mediaKeyTap.isRunning
        }

        publishState(writeDisk: true)
        evaluateRoute()
        updateAccessibilityPolling()
        publishState(writeDisk: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        flushPendingPersistence()
        topologyDebounceWorkItem?.cancel()
        topologyDebounceWorkItem = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        stopTimers()
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        dropRoute(sync: true)
        hotkeys.unregisterAll()
        mediaKeyTap.stop()
        removeSystemAudioListeners()
        xpcListener?.invalidate()
        xpcListener = nil
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { nc.removeObserver(token) }
        workspaceObservers.removeAll()
    }

    // MARK: - Authenticated Mach XPC Server

    private func startXPCListener() {
        let listener = NSXPCListener(machServiceName: VolumeIPC.xpcMachServiceName)
        listener.delegate = self
        let req = CodeSignInspector.peerCodeSigningRequirement(
            expectedBundleID: VolumeIPC.suiteName,
            matchingOwnIdentity: ownIdentity
        )
        listener.setConnectionCodeSigningRequirement(req)
        listener.resume()
        xpcListener = listener
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Enforce same-user UID boundary in addition to XPC code-signing requirement.
        guard newConnection.effectiveUserIdentifier == getuid() else {
            return false
        }
        newConnection.exportedInterface = VolumeIPC.makeXPCInterface()
        let proxy = EngineXPCProxy(engine: self, connection: newConnection)
        newConnection.exportedObject = proxy
        let connID = ObjectIdentifier(newConnection)
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleXPCDisconnect(connID)
            }
        }
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleXPCDisconnect(connID)
            }
        }
        newConnection.resume()
        return true
    }

    private func handleXPCDisconnect(_ connID: ObjectIdentifier) {
        if let clientID = connectionClientMap.removeValue(forKey: connID) {
            activeMediaKeyClients.remove(clientID)
            syncMediaKeyIntercept()
            publishState(writeDisk: false)
        }
    }

    fileprivate func currentEncodedState() -> Data? {
        let state = buildStateSnapshot()
        return try? JSONEncoder().encode(state)
    }

    fileprivate func xpcPing() -> (Int, Int, String) {
        (engineBuild, VolumeState.currentProtocolVersion, engineInstanceID)
    }

    fileprivate func xpcSetVolume(_ value: Int, deviceUID: String, isDragging: Bool, sourceRaw: String) -> Data? {
        guard phase == .active || phase == .checking,
              deviceUID.isEmpty || device?.uid == deviceUID else {
            return currentEncodedState()
        }
        let source = VolumeState.TriggerSource(rawValue: sourceRaw) ?? .slider
        setAbsoluteVolume(value, source: source, deferPersistence: isDragging)
        return currentEncodedState()
    }

    fileprivate func xpcStepVolume(_ delta: Int, deviceUID: String, sourceRaw: String) -> Data? {
        guard phase == .active || phase == .checking,
              deviceUID.isEmpty || device?.uid == deviceUID else {
            return currentEncodedState()
        }
        let source = VolumeState.TriggerSource(rawValue: sourceRaw) ?? .mediaKey
        applyStep(delta, source: source)
        return currentEncodedState()
    }

    fileprivate func xpcSetLimit(_ value: Int, deviceUID: String, isDragging: Bool) -> Data? {
        guard deviceUID.isEmpty || device?.uid == deviceUID else {
            return currentEncodedState()
        }
        setLimit(value, deferPersistence: isDragging)
        publishState(writeDisk: !isDragging)
        return currentEncodedState()
    }

    fileprivate func xpcToggleOutputMute(deviceUID: String, sourceRaw: String) -> Data? {
        guard phase == .active || phase == .checking,
              deviceUID.isEmpty || device?.uid == deviceUID else {
            return currentEncodedState()
        }
        let source = VolumeState.TriggerSource(rawValue: sourceRaw) ?? .slider
        toggleMute(source: source)
        return currentEncodedState()
    }

    fileprivate func xpcSetEnabled(_ wantEnabled: Bool) -> Data? {
        if wantEnabled {
            enabled = true
            message = nil
            retryAfter = 0
            unsupportedFormatDeviceUID = nil
            consecutiveRouteFailures = 0
            updateCurrentDeviceProfile(deferPersistence: false)
            evaluateRoute()
        } else {
            enabled = false
            message = nil
            updateCurrentDeviceProfile(deferPersistence: false)
            dropRoute(sync: false)
            syncMediaKeyIntercept()
        }
        publishState(writeDisk: true)
        return currentEncodedState()
    }

    /// Serialized single-writer microphone gain control inside Engine (eliminates dual-process HAL/UserDefaults race).
    fileprivate func xpcSetMicVolume(_ value: Int, deviceUID: String, isDragging: Bool) -> (Bool, Data?) {
        guard let mic = resolveInputDevice(expectedUID: deviceUID),
              mic.inputVolumeControlAvailable else {
            return (false, nil)
        }
        let ok = MicrophoneControl.applyVolume(
            value,
            for: mic,
            persistPreMute: !isDragging,
            clearMuteIfPositive: false
        )
        let status = MicrophoneControl.readStatus(for: mic)
        return (ok, try? JSONEncoder().encode(status))
    }

    /// Serialized single-writer microphone mute control inside Engine.
    fileprivate func xpcToggleMicMute(deviceUID: String, showHUD: Bool) -> (Bool, Data?) {
        guard let status = toggleDefaultMicMute(expectedUID: deviceUID.isEmpty ? nil : deviceUID, showHUD: showHUD) else {
            return (false, nil)
        }
        return (true, try? JSONEncoder().encode(status))
    }

    fileprivate func xpcSetPreference(_ key: String, flag: Bool) -> Data? {
        switch key {
        case "showOSD":
            showOSD = flag
            preferences.set(flag, forKey: "ShowOSD")
            if !flag { osd.hideImmediately() }
        case "showMenuBarPercent":
            showMenuBarPercent = flag
            preferences.set(flag, forKey: "ShowMenuBarPercent")
        case "scrollOnIcon":
            scrollOnIconEnabled = flag
            preferences.set(flag, forKey: "ScrollOnIconEnabled")
        default:
            break
        }
        publishState(writeDisk: true)
        return currentEncodedState()
    }

    fileprivate func xpcSetUIMediaKeysActive(_ active: Bool, clientInstanceID: String, connectionID: ObjectIdentifier) -> Data? {
        guard !clientInstanceID.isEmpty else { return currentEncodedState() }
        if active {
            connectionClientMap[connectionID] = clientInstanceID
            activeMediaKeyClients.insert(clientInstanceID)
        } else {
            activeMediaKeyClients.remove(clientInstanceID)
            if connectionClientMap[connectionID] == clientInstanceID {
                connectionClientMap.removeValue(forKey: connectionID)
            }
        }
        syncMediaKeyIntercept()
        publishState(writeDisk: false)
        return currentEncodedState()
    }

    fileprivate func xpcRequestAccessibility() -> Data? {
        _ = MediaKeyTap.requestAccessibilityPrompt()
        cachedAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted
        if cachedAccessibilityTrusted {
            _ = mediaKeyTap.start()
            mediaKeysActive = mediaKeyTap.isRunning
            syncMediaKeyIntercept()
        } else {
            updateAccessibilityPolling()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        publishState(writeDisk: true)
        return currentEncodedState()
    }

    fileprivate func xpcReverifyCapture() -> Data? {
        verifiedCapture = false
        preferences.set(false, forKey: "CaptureVerified")
        message = nil
        retryAfter = 0
        unsupportedFormatDeviceUID = nil
        consecutiveRouteFailures = 0
        dropRoute(sync: false)
        evaluateRoute()
        publishState(writeDisk: true)
        return currentEncodedState()
    }

    private func resolveInputDevice(expectedUID: String?) -> AudioDeviceInfo? {
        guard let mic = InputDeviceCatalog.currentDefault() else { return nil }
        if let expectedUID, !expectedUID.isEmpty, mic.uid != expectedUID {
            return nil
        }
        return mic
    }

    // MARK: - Preference Migration & Per-Device Profiles

    private func loadAndMigratePreferences() {
        if !preferences.bool(forKey: "DidMigrateFromLegacyRedmiVolume"),
           let legacy = UserDefaults(suiteName: VolumeIPC.legacySuiteName),
           legacy.object(forKey: "VolumePercent") != nil || legacy.object(forKey: "VolumeLimit") != nil {
            let legacyLimit = min(100, max(1, legacy.object(forKey: "VolumeLimit") as? Int ?? 100))
            let legacyVol = min(legacyLimit, max(1, legacy.object(forKey: "VolumePercent") as? Int ?? 60))
            let legacyMuted = legacy.bool(forKey: "SoftwareMuted")
            let legacyEnabled = legacy.object(forKey: "BackgroundVolumeEnabled") as? Bool ?? true
            let legacyVerified = legacy.bool(forKey: "BackgroundCaptureVerified")

            preferences.set(legacyLimit, forKey: "DefaultVolumeLimit")
            preferences.set(legacyVol, forKey: "DefaultVolumePercent")
            preferences.set(legacyMuted, forKey: "DefaultMuted")
            preferences.set(legacyEnabled, forKey: "DefaultEnabled")
            preferences.set(legacyVerified, forKey: "CaptureVerified")

            if let dev = device, dev.isAutoControllable {
                profiles[dev.uid] = DeviceVolumeProfile(
                    volume: legacyVol,
                    volumeLimit: legacyLimit,
                    muted: legacyMuted,
                    enabled: legacyEnabled
                )
                saveProfilesNow()
            }
            preferences.set(true, forKey: "DidMigrateFromLegacyRedmiVolume")
        }

        if let data = preferences.data(forKey: "DeviceProfiles"),
           let decoded = try? JSONDecoder().decode([String: DeviceVolumeProfile].self, from: data) {
            profiles = decoded
        }

        verifiedCapture = preferences.bool(forKey: "CaptureVerified")
        showOSD = preferences.object(forKey: "ShowOSD") as? Bool ?? true
        showMenuBarPercent = preferences.bool(forKey: "ShowMenuBarPercent")
        scrollOnIconEnabled = preferences.object(forKey: "ScrollOnIconEnabled") as? Bool ?? true

        loadProfileForCurrentDevice()
    }

    /// Single atomic entry point for changing the active device and loading its volume profile.
    private func commitDeviceChange(_ latest: AudioDeviceInfo?) {
        let identityChanged = (latest?.uid != device?.uid || latest?.id != device?.id)
        device = latest
        if identityChanged {
            loadProfileForCurrentDevice()
            retryAfter = 0
            message = nil
            unsupportedFormatDeviceUID = nil
            consecutiveRouteFailures = 0
        }
        if let latest {
            installActiveDeviceListeners(for: latest.id)
        } else {
            removeActiveDeviceListeners()
        }
    }

    private func loadProfileForCurrentDevice() {
        guard let dev = device else {
            let fallbackLimit = min(100, max(1, preferences.object(forKey: "DefaultVolumeLimit") as? Int ?? 100))
            limit = fallbackLimit
            volume = min(fallbackLimit, max(1, preferences.object(forKey: "DefaultVolumePercent") as? Int ?? 50))
            muted = preferences.bool(forKey: "DefaultMuted")
            enabled = preferences.object(forKey: "DefaultEnabled") as? Bool ?? true
            return
        }

        if let existing = profiles[dev.uid] {
            limit = min(100, max(1, existing.volumeLimit))
            volume = min(limit, max(1, existing.volume))
            muted = existing.muted
            enabled = existing.enabled
        } else {
            let fallbackLimit = min(100, max(1, preferences.object(forKey: "DefaultVolumeLimit") as? Int ?? 100))
            let fallbackVol = min(fallbackLimit, max(1, preferences.object(forKey: "DefaultVolumePercent") as? Int ?? 50))
            limit = fallbackLimit
            volume = fallbackVol
            muted = false
            enabled = true
            if dev.isAutoControllable {
                profiles[dev.uid] = DeviceVolumeProfile(volume: volume, volumeLimit: limit, muted: muted, enabled: enabled)
                schedulePersistence()
            }
        }
    }

    private func updateCurrentDeviceProfile(deferPersistence: Bool = true) {
        guard let dev = device, dev.isAutoControllable else { return }
        profiles[dev.uid] = DeviceVolumeProfile(volume: volume, volumeLimit: limit, muted: muted, enabled: enabled)
        if deferPersistence {
            schedulePersistence()
        } else {
            flushPendingPersistence()
        }
    }

    private func schedulePersistence() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingPersistence()
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flushPendingPersistence() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        saveProfilesNow()
        let state = buildStateSnapshot()
        lastPublishedState = state
        VolumeIPC.publish(state, writeDisk: true, notify: false)
    }

    private func saveProfilesNow() {
        if let encoded = try? JSONEncoder().encode(profiles) {
            preferences.set(encoded, forKey: "DeviceProfiles")
        }
        preferences.set(volume, forKey: "DefaultVolumePercent")
        preferences.set(limit, forKey: "DefaultVolumeLimit")
        preferences.set(muted, forKey: "DefaultMuted")
        preferences.set(enabled, forKey: "DefaultEnabled")
    }

    // MARK: - Media Keys & Volume Mutations

    private func handleMediaKey(_ action: MediaKeyAction) {
        guard phase == .active || phase == .checking else { return }
        switch action {
        case .volumeUp(let fine):
            applyStep(fine ? 1 : 5, source: .mediaKey)
        case .volumeDown(let fine):
            applyStep(fine ? -1 : -5, source: .mediaKey)
        case .toggleMute:
            toggleMute(source: .mediaKey)
        }
    }

    private func setAbsoluteVolume(_ rawValue: Int, source: VolumeState.TriggerSource, deferPersistence: Bool) {
        let clamped = VolumeMath.clampedVolume(rawValue, limit: limit)
        if clamped > 0 {
            volume = clamped
            muted = false
        } else {
            muted = true
        }
        applyGain()
        recordTrigger(source)
        updateCurrentDeviceProfile(deferPersistence: deferPersistence)
        publishState(writeDisk: !deferPersistence)
    }

    private func applyStep(_ delta: Int, source: VolumeState.TriggerSource) {
        let next = VolumeMath.applyStep(currentVolume: volume, limit: limit, muted: muted, delta: delta)
        volume = next.volume
        muted = next.muted
        applyGain()
        recordTrigger(source)
        updateCurrentDeviceProfile(deferPersistence: true)
        publishState(writeDisk: false)
    }

    private func toggleMute(source: VolumeState.TriggerSource) {
        muted.toggle()
        applyGain()
        recordTrigger(source)
        updateCurrentDeviceProfile(deferPersistence: false)
        publishState(writeDisk: true)
    }

    @discardableResult
    private func toggleDefaultMicMute(expectedUID: String?, showHUD: Bool) -> MicrophoneControl.Status? {
        guard let mic = resolveInputDevice(expectedUID: expectedUID),
              let status = MicrophoneControl.toggleMute(for: mic) else { return nil }
        if showHUD && showOSD {
            osd.showMic(volume: status.volumePercent, muted: status.muted, deviceName: mic.name)
        }
        return status
    }

    private func setLimit(_ rawLimit: Int, deferPersistence: Bool) {
        limit = min(100, max(1, rawLimit))
        volume = min(volume, limit)
        applyGain()
        updateCurrentDeviceProfile(deferPersistence: deferPersistence)
    }

    private func applyGain() {
        route?.setVolume(Double(muted ? 0 : min(volume, limit)) / 100.0)
    }

    private func recordTrigger(_ source: VolumeState.TriggerSource) {
        lastTriggerSource = source
        lastTriggerNonce &+= 1
        if showOSD, source == .mediaKey || source == .hotkey || source == .scroll {
            osd.show(
                volume: min(volume, limit),
                limit: limit,
                muted: muted,
                deviceName: device?.name ?? L10n.appName
            )
        }
    }

    // MARK: - Event-Driven CoreAudio & Sleep Routing

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemSleeping = true
                    self?.retryWorkItem?.cancel()
                    self?.retryWorkItem = nil
                    self?.dropRoute(sync: false)
                    self?.syncMediaKeyIntercept()
                    self?.publishState(writeDisk: true)
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemSleeping = false
                    self?.screensSleeping = false
                    self?.retryAfter = 0
                    self?.consecutiveRouteFailures = 0
                    self?.handleDeviceTopologyChange()
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensSleeping = true
                    self?.retryWorkItem?.cancel()
                    self?.retryWorkItem = nil
                    if self?.device?.transportKind.isExternalDisplayOrDigital == true {
                        self?.dropRoute(sync: false)
                        self?.syncMediaKeyIntercept()
                        self?.publishState(writeDisk: false)
                    }
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensSleeping = false
                    self?.retryAfter = 0
                    self?.consecutiveRouteFailures = 0
                    self?.handleDeviceTopologyChange()
                }
            }
        )
    }

    private func installSystemAudioListeners() {
        guard !systemListenersInstalled else { return }
        systemListenersInstalled = true

        var defaultAddr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDeviceTopologyChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, DispatchQueue.main, defaultBlock) == noErr {
            defaultOutputListener = defaultBlock
        }

        var devicesAddr = audioAddress(kAudioHardwarePropertyDevices)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleTopologyChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock) == noErr {
            devicesListListener = devicesBlock
        }
    }

    private func scheduleTopologyChange() {
        topologyDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.topologyDebounceWorkItem = nil
            self?.handleDeviceTopologyChange()
        }
        topologyDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func removeSystemAudioListeners() {
        removeActiveDeviceListeners()
        if let block = defaultOutputListener {
            var addr = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        if let block = devicesListListener {
            var addr = audioAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        defaultOutputListener = nil
        devicesListListener = nil
        systemListenersInstalled = false
    }

    private func installActiveDeviceListeners(for deviceID: AudioDeviceID) {
        if observedDeviceID == deviceID { return }
        removeActiveDeviceListeners()
        guard deviceID != kAudioObjectUnknown else { return }
        observedDeviceID = deviceID

        var aliveAddr = audioAddress(kAudioDevicePropertyDeviceIsAlive)
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDeviceTopologyChange() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddr, DispatchQueue.main, aliveBlock) == noErr {
            deviceAliveListener = aliveBlock
        }

        var runningAddr = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let runningBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.evaluateCheckingSignal() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &runningAddr, DispatchQueue.main, runningBlock) == noErr {
            deviceRunningListener = runningBlock
        }
    }

    private func removeActiveDeviceListeners() {
        if observedDeviceID != kAudioObjectUnknown {
            if let block = deviceAliveListener {
                var addr = audioAddress(kAudioDevicePropertyDeviceIsAlive)
                AudioObjectRemovePropertyListenerBlock(observedDeviceID, &addr, DispatchQueue.main, block)
            }
            if let block = deviceRunningListener {
                var addr = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
                AudioObjectRemovePropertyListenerBlock(observedDeviceID, &addr, DispatchQueue.main, block)
            }
        }
        deviceAliveListener = nil
        deviceRunningListener = nil
        observedDeviceID = kAudioObjectUnknown
    }

    private func handleDeviceTopologyChange() {
        topologyDebounceWorkItem?.cancel()
        topologyDebounceWorkItem = nil
        cachedAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted
        let latest = OutputDeviceCatalog.currentDefault()
        commitDeviceChange(latest)
        evaluateRoute()
        publishState(writeDisk: true)
    }

    private func evaluateRoute() {
        let current = OutputDeviceCatalog.currentDefault()
        if current?.uid != device?.uid || current?.id != device?.id {
            commitDeviceChange(current)
        }
        guard !isAsleepForCurrentDevice else { return }

        let now = ProcessInfo.processInfo.systemUptime

        if let route {
            if current == nil || current?.uid != route.device.uid || current?.id != route.device.id || !route.device.isAlive || !enabled || current?.isAutoControllable != true {
                dropRoute(sync: false)
            } else if route.layoutChanged {
                dropRoute(reason: L10n.text("声音格式已变化，正在重新连接…", "Audio format changed, reconnecting…"), sync: false)
                scheduleRetry(after: 1.0)
            }
        }

        if enabled,
           route == nil,
           inFlightRouteGeneration == nil,
           now >= retryAfter,
           let current,
           current.isAutoControllable,
           current.isAlive,
           unsupportedFormatDeviceUID != current.uid {
            startRouteAsync(for: current)
        }
        syncMediaKeyIntercept()
    }

    /// Runs `AudioRoute.start` on `routeQueue` with generation validation so `AudioDeviceStart` never stalls MainActor.
    private func startRouteAsync(for target: AudioDeviceInfo) {
        routeGeneration &+= 1
        let gen = routeGeneration
        inFlightRouteGeneration = gen
        let initialFraction = Double(muted ? 0 : min(volume, limit)) / 100.0
        let useImmediate = verifiedCapture
        let candidate = AudioRoute(device: target)

        routeQueue.async { [weak self] in
            let result: Result<AudioRoute, Error>
            do {
                try candidate.start(immediateVolume: useImmediate ? initialFraction : nil)
                result = .success(candidate)
            } catch {
                candidate.stop()
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    candidate.stop()
                    return
                }
                if self.inFlightRouteGeneration == gen {
                    self.inFlightRouteGeneration = nil
                }
                guard gen == self.routeGeneration,
                      !self.isAsleepForCurrentDevice,
                      self.enabled,
                      self.device?.uid == target.uid else {
                    // Route superseded while starting — tear down off MainActor and re-evaluate only if no newer start is active.
                    self.routeQueue.async { candidate.stop() }
                    if self.inFlightRouteGeneration == nil {
                        self.evaluateRoute()
                    }
                    return
                }

                switch result {
                case .success(let activeRoute):
                    activeRoute.onStreamFormatChanged = { [weak self] in
                        Task { @MainActor in
                            guard let self, self.route === activeRoute else { return }
                            self.dropRoute(reason: L10n.text("采样率已切换，正在重新连接…", "Sample rate changed, reconnecting…"), sync: false)
                            self.scheduleRetry(after: 0.4)
                            self.publishState(writeDisk: false)
                        }
                    }
                    self.route = activeRoute
                    self.message = nil
                    self.consecutiveRouteFailures = 0
                    self.unsupportedFormatDeviceUID = nil
                    self.applyGain()

                    if useImmediate {
                        self.activateState(for: activeRoute)
                    } else {
                        self.phase = .checking
                        self.runningWithZeroSignalSince = nil
                        self.startCheckingTimer()
                    }
                    self.syncMediaKeyIntercept()
                    self.publishState(writeDisk: true)

                case .failure(let error):
                    if let audioErr = error as? AudioFailure, audioErr.status == kAudioDeviceUnsupportedFormatError {
                        self.unsupportedFormatDeviceUID = target.uid
                        self.dropRoute(
                            reason: L10n.text("当前音频流格式暂不支持软件控音，切换格式或设备后将自动重试。", "Current audio stream format is unsupported; will retry on format or device change."),
                            sync: false
                        )
                    } else {
                        self.consecutiveRouteFailures += 1
                        let backoff = min(30.0, 2.0 * pow(2.0, Double(min(4, self.consecutiveRouteFailures - 1))))
                        self.dropRoute(reason: error.localizedDescription, sync: false)
                        self.scheduleRetry(after: backoff)
                    }
                    self.publishState(writeDisk: true)
                }
            }
        }
    }

    private func activateState(for activeRoute: AudioRoute) {
        callbackCount = activeRoute.callbackCount
        renderedCallbackCount = activeRoute.renderedCallbackCount
        lastCallbackTime = ProcessInfo.processInfo.systemUptime
        phase = .active
        runningWithZeroSignalSince = nil
        checkingTimer?.invalidate()
        checkingTimer = nil
        outputHotkeysAvailable = hotkeys.register()
        if cachedAccessibilityTrusted && !mediaKeyTap.isRunning {
            _ = mediaKeyTap.start()
        }
        mediaKeysActive = mediaKeyTap.isRunning
        startWatchdogTimer()
        syncMediaKeyIntercept()
    }

    private func evaluateCheckingSignal() {
        guard phase == .checking, let route else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if route.layoutChanged {
            dropRoute(reason: L10n.text("声音格式已变化，正在重新连接…", "Audio format changed, reconnecting…"), sync: false)
            scheduleRetry(after: 1.0)
            publishState(writeDisk: false)
            return
        }
        if route.hasSignal {
            do {
                try route.activate(volume: Double(muted ? 0 : min(volume, limit)) / 100.0)
                verifiedCapture = true
                preferences.set(true, forKey: "CaptureVerified")
                activateState(for: route)
                publishState(writeDisk: true)
            } catch {
                dropRoute(reason: error.localizedDescription, sync: false)
                scheduleRetry(after: 4.0)
                publishState(writeDisk: true)
            }
            return
        }

        // Keep retryable (never permanently set enabled = false on silent playback tracks).
        if route.device.isRunningSomewhere {
            if runningWithZeroSignalSince == nil {
                runningWithZeroSignalSince = now
            } else if let since = runningWithZeroSignalSince, now - since > 8.0 {
                message = L10n.text(
                    "尚未检测到有效音频信号。若持续无反应，请检查「隐私与安全性 → 录屏与系统录音」权限并播放非静音音频。",
                    "No audio signal detected yet. Check System Audio Recording permission and play non-silent audio."
                )
                publishState(writeDisk: false)
            }
        } else {
            runningWithZeroSignalSince = nil
        }
    }

    private func dropRoute(reason: String? = nil, sync: Bool) {
        routeGeneration &+= 1
        inFlightRouteGeneration = nil
        stopTimers()
        let oldRoute = route
        route = nil
        phase = .idle
        runningWithZeroSignalSince = nil
        message = reason
        outputHotkeysAvailable = false
        hotkeys.unregisterOutput()
        syncMediaKeyIntercept()

        if let oldRoute {
            if sync {
                routeQueue.sync { oldRoute.stop() }
            } else {
                routeQueue.async { oldRoute.stop() }
            }
        }
    }

    private func syncMediaKeyIntercept() {
        if uiHandlesMediaKeys {
            mediaKeyTap.shouldIntercept = false
            mediaKeysActive = true
            return
        }
        let trusted = cachedAccessibilityTrusted || MediaKeyTap.isAccessibilityTrusted
        cachedAccessibilityTrusted = trusted
        if trusted && !mediaKeyTap.isRunning {
            _ = mediaKeyTap.start()
        }
        mediaKeysActive = mediaKeyTap.isRunning
        let activeControl = enabled && (phase == .active || phase == .checking) && (device?.isAutoControllable == true)
        mediaKeyTap.shouldIntercept = trusted && mediaKeysActive && activeControl
    }

    private func startCheckingTimer() {
        checkingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, target: self, selector: #selector(onCheckTick), userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        checkingTimer = timer
    }

    private func startWatchdogTimer() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, target: self, selector: #selector(onWatchdogTick), userInfo: nil, repeats: true)
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopTimers() {
        checkingTimer?.invalidate()
        checkingTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryWorkItem?.cancel()
        retryAfter = ProcessInfo.processInfo.systemUptime + delay
        let work = DispatchWorkItem { [weak self] in
            self?.retryWorkItem = nil
            self?.evaluateRoute()
            self?.publishState(writeDisk: false)
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        cachedAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted
        guard !cachedAccessibilityTrusted else { return }
        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(onAccessibilityPoll), userInfo: nil, repeats: true)
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPollTimer = timer
    }

    @objc private func onCheckTick() {
        evaluateCheckingSignal()
    }

    @objc private func onWatchdogTick() {
        guard !isAsleepForCurrentDevice, phase == .active, let route else { return }
        if !route.device.isAlive {
            handleDeviceTopologyChange()
            return
        }
        if route.layoutChanged {
            dropRoute(reason: L10n.text("音频通道格式变化，正在重新连接…", "Audio layout changed, reconnecting…"), sync: false)
            scheduleRetry(after: 1.0)
            publishState(writeDisk: false)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let latestCB = route.callbackCount
        let latestRendered = route.renderedCallbackCount
        if latestRendered != renderedCallbackCount {
            callbackCount = latestCB
            renderedCallbackCount = latestRendered
            lastCallbackTime = now
        } else if !route.device.isRunningSomewhere {
            callbackCount = latestCB
            lastCallbackTime = now
        } else if now - lastCallbackTime > 3.5 {
            dropRoute(reason: L10n.text("音频通道暂时中断，正在重新连接…", "Audio stream interrupted, reconnecting…"), sync: false)
            scheduleRetry(after: 1.5)
            publishState(writeDisk: false)
        }
    }

    @objc private func onAccessibilityPoll() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        guard trusted else { return }
        cachedAccessibilityTrusted = true
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        syncMediaKeyIntercept()
        publishState(writeDisk: true)
    }

    private func buildStateSnapshot() -> VolumeState {
        let trusted = cachedAccessibilityTrusted
        return VolumeState(
            protocolVersion: VolumeState.currentProtocolVersion,
            engineBuild: engineBuild,
            engineInstanceID: engineInstanceID,
            stateSequence: stateSequence,
            routeGeneration: routeGeneration,
            enginePID: getpid(),
            phase: phase,
            deviceUID: device?.uid,
            deviceName: device?.name,
            transportLabel: device?.transportKind.displayLabel,
            isLockedOutput: device?.volumeControlAvailable == false,
            isControllable: device?.isAutoControllable == true,
            volume: volume,
            volumeLimit: limit,
            muted: muted,
            enabled: enabled,
            verifiedCapture: verifiedCapture,
            mediaKeysAuthorized: uiHandlesMediaKeys || trusted,
            mediaKeysActive: uiHandlesMediaKeys || (trusted && mediaKeyTap.isRunning),
            shortcutsAvailable: outputHotkeysAvailable,
            micHotkeyAvailable: micHotkeyAvailable,
            showOSD: showOSD,
            showMenuBarPercent: showMenuBarPercent,
            scrollOnIconEnabled: scrollOnIconEnabled,
            lastTriggerSource: lastTriggerSource,
            lastTriggerNonce: lastTriggerNonce,
            message: message
        )
    }

    private func publishState(writeDisk: Bool) {
        var candidate = buildStateSnapshot()
        if let prev = lastPublishedState {
            var prevComparable = prev
            prevComparable.stateSequence = candidate.stateSequence
            if prevComparable == candidate {
                if writeDisk {
                    VolumeIPC.publish(prev, writeDisk: true, notify: false)
                }
                return
            }
        }
        stateSequence &+= 1
        candidate.stateSequence = stateSequence
        lastPublishedState = candidate
        VolumeIPC.publish(candidate, writeDisk: writeDisk, notify: true)
    }
}

/// Bridges ObjC XPC invocations cleanly onto `@MainActor` VolumeEngine.
private final class EngineXPCProxy: NSObject, DisplayVolumeEngineXPCProtocol {
    private weak var engine: VolumeEngine?
    private let connectionID: ObjectIdentifier

    init(engine: VolumeEngine, connection: NSXPCConnection) {
        self.engine = engine
        self.connectionID = ObjectIdentifier(connection)
    }

    func ping(withReply reply: @escaping (Int, Int, String) -> Void) {
        Task { @MainActor in
            guard let engine = self.engine else { reply(0, 0, ""); return }
            let info = engine.xpcPing()
            reply(info.0, info.1, info.2)
        }
    }

    func fetchState(withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.currentEncodedState())
        }
    }

    func setVolume(_ value: Int, deviceUID: String, isDragging: Bool, source: String, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcSetVolume(value, deviceUID: deviceUID, isDragging: isDragging, sourceRaw: source))
        }
    }

    func stepVolume(_ delta: Int, deviceUID: String, source: String, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcStepVolume(delta, deviceUID: deviceUID, sourceRaw: source))
        }
    }

    func setLimit(_ limit: Int, deviceUID: String, isDragging: Bool, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcSetLimit(limit, deviceUID: deviceUID, isDragging: isDragging))
        }
    }

    func toggleOutputMute(deviceUID: String, source: String, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcToggleOutputMute(deviceUID: deviceUID, sourceRaw: source))
        }
    }

    func setEnabled(_ enabled: Bool, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcSetEnabled(enabled))
        }
    }

    func setMicVolume(_ value: Int, deviceUID: String, isDragging: Bool, withReply reply: @escaping (Bool, Data?) -> Void) {
        Task { @MainActor in
            guard let engine = self.engine else { reply(false, nil); return }
            let res = engine.xpcSetMicVolume(value, deviceUID: deviceUID, isDragging: isDragging)
            reply(res.0, res.1)
        }
    }

    func toggleMicMute(deviceUID: String, showOSD: Bool, withReply reply: @escaping (Bool, Data?) -> Void) {
        Task { @MainActor in
            guard let engine = self.engine else { reply(false, nil); return }
            let res = engine.xpcToggleMicMute(deviceUID: deviceUID, showHUD: showOSD)
            reply(res.0, res.1)
        }
    }

    func setPreference(_ key: String, flag: Bool, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcSetPreference(key, flag: flag))
        }
    }

    func setUIMediaKeysActive(_ active: Bool, clientInstanceID: String, withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcSetUIMediaKeysActive(active, clientInstanceID: clientInstanceID, connectionID: self.connectionID))
        }
    }

    func requestAccessibility(withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcRequestAccessibility())
        }
    }

    func reverifyCapture(withReply reply: @escaping (Data?) -> Void) {
        Task { @MainActor in
            reply(self.engine?.xpcReverifyCapture())
        }
    }
}

@main
private struct EngineMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let engine = VolumeEngine()
        app.setActivationPolicy(.accessory)
        app.delegate = engine
        app.run()
    }
}
