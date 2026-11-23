import AppKit
import CoreAudio

@MainActor
private final class VolumeEngine: NSObject, NSApplicationDelegate {
    private let preferences = UserDefaults(suiteName: VolumeIPC.suiteName)!
    private let osd = VolumeOSD()

    private var device: AudioDeviceInfo? = OutputDeviceCatalog.currentDefault()
    private var phase = VolumeState.Phase.idle
    private var route: AudioRoute?
    private var profiles: [String: DeviceVolumeProfile] = [:]

    private var volume: Int = 50
    private var limit: Int = 100
    private var muted: Bool = false
    private var enabled: Bool = true
    private var verifiedCapture: Bool = false
    private var showOSD: Bool = true
    private var showMenuBarPercent: Bool = false
    private var scrollOnIconEnabled: Bool = true

    private var shortcuts = false
    private var mediaKeysActive = false
    private var uiHandlesMediaKeys = false
    private var message: String?
    private var lastTriggerSource: VolumeState.TriggerSource?
    private var lastTriggerNonce: UInt64 = 0

    private var checkingTimer: Timer?
    private var watchdogTimer: Timer?
    private var accessibilityPollTimer: Timer?
    private var persistWorkItem: DispatchWorkItem?

    private var systemListenersInstalled = false
    private var observedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var deviceRunningListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var devicesListListener: AudioObjectPropertyListenerBlock?
    private var workspaceObservers: [NSObjectProtocol] = []

    private var sleeping = false
    private var retryAfter: TimeInterval = 0
    private var runningWithZeroSignalSince: TimeInterval?
    private var callbackCount: UInt32 = 0
    private var lastCallbackTime: TimeInterval = 0
    private var lastPublishedState: VolumeState?

    private lazy var mediaKeyTap = MediaKeyTap { [weak self] action in
        self?.handleMediaKey(action)
    }

    private lazy var hotkeys = Hotkeys { [weak self] key in
        guard let self, self.phase == .active else { return }
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
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receive(_:)),
            name: VolumeIPC.command,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        installWorkspaceObservers()
        installSystemAudioListeners()

        // Start media key tap immediately if Accessibility is already trusted.
        if MediaKeyTap.isAccessibilityTrusted {
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
        stopTimers()
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        dropRoute()
        mediaKeyTap.stop()
        removeSystemAudioListeners()
        DistributedNotificationCenter.default().removeObserver(self)
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { nc.removeObserver(token) }
        workspaceObservers.removeAll()
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

    private func updateCurrentDeviceProfile() {
        guard let dev = device, dev.isAutoControllable else { return }
        profiles[dev.uid] = DeviceVolumeProfile(volume: volume, volumeLimit: limit, muted: muted, enabled: enabled)
        schedulePersistence()
    }

    private func schedulePersistence() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingPersistence()
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func flushPendingPersistence() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        saveProfilesNow()
        if let state = lastPublishedState {
            VolumeIPC.publish(state, writeDisk: true, notify: false)
        }
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

    // MARK: - IPC Commands

    @objc private func receive(_ notification: Notification) {
        guard let raw = notification.userInfo?["action"] as? String,
              let command = VolumeCommand(rawValue: raw) else { return }
        let sourceRaw = notification.userInfo?["source"] as? String
        let source = sourceRaw.flatMap(VolumeState.TriggerSource.init(rawValue:)) ?? .slider

        switch command {
        case .enable:
            enabled = true
            message = nil
            retryAfter = 0
            updateCurrentDeviceProfile()
            evaluateRoute()
        case .pause:
            enabled = false
            message = nil
            updateCurrentDeviceProfile()
            dropRoute()
            syncMediaKeyIntercept()
        case .volume:
            if phase == .active, let value = notification.userInfo?["value"] as? Int {
                setAbsoluteVolume(value, source: source)
            }
        case .step:
            if phase == .active, let delta = notification.userInfo?["value"] as? Int {
                applyStep(delta, source: source)
            }
        case .limit:
            if let value = notification.userInfo?["value"] as? Int {
                setLimit(value)
            }
        case .mute:
            if phase == .active {
                toggleMute(source: source)
            }
        case .requestAccessibility:
            _ = MediaKeyTap.requestAccessibilityPrompt()
            if MediaKeyTap.isAccessibilityTrusted {
                _ = mediaKeyTap.start()
                mediaKeysActive = mediaKeyTap.isRunning
                syncMediaKeyIntercept()
            } else {
                updateAccessibilityPolling()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .setShowOSD:
            if let flag = notification.userInfo?["flag"] as? Bool {
                showOSD = flag
                preferences.set(flag, forKey: "ShowOSD")
                if !flag { osd.hideImmediately() }
            }
        case .setShowMenuBarPercent:
            if let flag = notification.userInfo?["flag"] as? Bool {
                showMenuBarPercent = flag
                preferences.set(flag, forKey: "ShowMenuBarPercent")
            }
        case .setScrollOnIcon:
            if let flag = notification.userInfo?["flag"] as? Bool {
                scrollOnIconEnabled = flag
                preferences.set(flag, forKey: "ScrollOnIconEnabled")
            }
        case .setUIMediaKeysActive:
            if let flag = notification.userInfo?["flag"] as? Bool {
                uiHandlesMediaKeys = flag
                syncMediaKeyIntercept()
                publishState(writeDisk: true)
                return
            }
        case .reverifyCapture:
            verifiedCapture = false
            preferences.set(false, forKey: "CaptureVerified")
            message = nil
            retryAfter = 0
            dropRoute()
            evaluateRoute()
        case .shutdownEngine:
            NSApp.terminate(nil)
            return
        }
        publishState(writeDisk: false)
    }

    // MARK: - Media Keys & Volume Mutations

    private func handleMediaKey(_ action: MediaKeyAction) {
        guard phase == .active || phase == .checking else { return }
        if phase == .checking, !verifiedCapture {
            // Even while verifying capture on first run, let user nudge target volume cleanly.
        }
        switch action {
        case .volumeUp(let fine):
            applyStep(fine ? 1 : 5, source: .mediaKey)
        case .volumeDown(let fine):
            applyStep(fine ? -1 : -5, source: .mediaKey)
        case .toggleMute:
            toggleMute(source: .mediaKey)
        }
    }

    private func setAbsoluteVolume(_ rawValue: Int, source: VolumeState.TriggerSource) {
        let clamped = VolumeMath.clampedVolume(rawValue, limit: limit)
        if clamped > 0 {
            volume = clamped
            muted = false
        } else {
            muted = true
        }
        applyGain()
        recordTrigger(source)
        updateCurrentDeviceProfile()
        publishState(writeDisk: false)
    }

    private func applyStep(_ delta: Int, source: VolumeState.TriggerSource) {
        let next = VolumeMath.applyStep(currentVolume: volume, limit: limit, muted: muted, delta: delta)
        volume = next.volume
        muted = next.muted
        applyGain()
        recordTrigger(source)
        updateCurrentDeviceProfile()
        publishState(writeDisk: false)
    }

    private func toggleMute(source: VolumeState.TriggerSource) {
        muted.toggle()
        applyGain()
        recordTrigger(source)
        updateCurrentDeviceProfile()
        publishState(writeDisk: false)
    }

    private func setLimit(_ rawLimit: Int) {
        limit = min(100, max(1, rawLimit))
        volume = min(volume, limit)
        applyGain()
        updateCurrentDeviceProfile()
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
                    self?.sleeping = true
                    self?.dropRoute()
                    self?.syncMediaKeyIntercept()
                    self?.publishState(writeDisk: true)
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleeping = false
                    self?.retryAfter = 0
                    self?.handleDeviceTopologyChange()
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // DisplayPort monitors can power down audio while Mac stays awake; drop cleanly so wake reconnects instantly.
                    if self?.device?.transportKind.isExternalDisplayOrDigital == true {
                        self?.dropRoute()
                        self?.syncMediaKeyIntercept()
                        self?.publishState(writeDisk: false)
                    }
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retryAfter = 0
                    self?.handleDeviceTopologyChange()
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let terminatedBundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                if terminatedBundle == VolumeIPC.suiteName {
                    MainActor.assumeIsolated {
                        self?.uiHandlesMediaKeys = false
                        self?.syncMediaKeyIntercept()
                        self?.publishState(writeDisk: false)
                    }
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
            Task { @MainActor in self?.handleDeviceTopologyChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock) == noErr {
            devicesListListener = devicesBlock
        }
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
        let latest = OutputDeviceCatalog.currentDefault()
        if latest?.uid != device?.uid || latest?.id != device?.id {
            device = latest
            loadProfileForCurrentDevice()
            retryAfter = 0
            message = nil
        } else {
            device = latest
        }
        if let latest {
            installActiveDeviceListeners(for: latest.id)
        } else {
            removeActiveDeviceListeners()
        }
        evaluateRoute()
        publishState(writeDisk: true)
    }

    private func evaluateRoute() {
        guard !sleeping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let current = OutputDeviceCatalog.currentDefault()
        device = current
        if let current { installActiveDeviceListeners(for: current.id) }

        if let route {
            if current == nil || current?.uid != route.device.uid || current?.id != route.device.id || !route.device.isAlive || !enabled || current?.isAutoControllable != true {
                dropRoute()
            } else if route.layoutChanged {
                dropRoute(reason: L10n.text("声音格式已变化，正在重新连接…", "Audio format changed, reconnecting…"))
                scheduleRetry(after: 1.5)
            }
        }

        if enabled, route == nil, now >= retryAfter, let current, current.isAutoControllable, current.isAlive {
            startRoute(for: current)
        }
        syncMediaKeyIntercept()
    }

    private func startRoute(for target: AudioDeviceInfo) {
        let candidate = AudioRoute(device: target)
        candidate.onStreamFormatChanged = { [weak self] in
            guard let self else { return }
            self.dropRoute(reason: L10n.text("采样率已切换，正在平滑重连…", "Sample rate changed, reconnecting…"))
            self.scheduleRetry(after: 0.4)
        }

        let initialFraction = Double(muted ? 0 : min(volume, limit)) / 100.0
        do {
            // Once capture permission is verified, engage attenuation synchronously so first sample never blasts 100%.
            try candidate.start(immediateVolume: verifiedCapture ? initialFraction : nil)
            route = candidate
            message = nil

            if verifiedCapture {
                activateState(for: candidate)
            } else {
                phase = .checking
                runningWithZeroSignalSince = nil
                startCheckingTimer()
            }
        } catch {
            dropRoute(reason: error.localizedDescription)
            scheduleRetry(after: 4.0)
        }
        syncMediaKeyIntercept()
    }

    private func activateState(for activeRoute: AudioRoute) {
        callbackCount = activeRoute.callbackCount
        lastCallbackTime = ProcessInfo.processInfo.systemUptime
        phase = .active
        runningWithZeroSignalSince = nil
        checkingTimer?.invalidate()
        checkingTimer = nil
        shortcuts = hotkeys.register()
        if MediaKeyTap.isAccessibilityTrusted && !mediaKeyTap.isRunning {
            _ = mediaKeyTap.start()
        }
        mediaKeysActive = mediaKeyTap.isRunning
        startWatchdogTimer()
        syncMediaKeyIntercept()
    }

    private func evaluateCheckingSignal() {
        guard phase == .checking, let route else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if route.hasSignal {
            do {
                try route.activate(volume: Double(muted ? 0 : min(volume, limit)) / 100.0)
                verifiedCapture = true
                preferences.set(true, forKey: "CaptureVerified")
                activateState(for: route)
                publishState(writeDisk: true)
            } catch {
                dropRoute(reason: error.localizedDescription)
                scheduleRetry(after: 4.0)
                publishState(writeDisk: true)
            }
            return
        }

        // Only count permission timeout while an app is actively sending audio to the device.
        if route.device.isRunningSomewhere {
            if runningWithZeroSignalSince == nil {
                runningWithZeroSignalSince = now
            } else if let since = runningWithZeroSignalSince, now - since > 8.0 {
                dropRoute(reason: L10n.text("未能读取系统音频，请在「隐私与安全性 → 录屏与系统录音」中允许桌面音量后台。", "System audio capture unavailable. Allow DisplayVolume Engine in Privacy & Security."))
                enabled = false
                updateCurrentDeviceProfile()
                publishState(writeDisk: true)
            }
        } else {
            runningWithZeroSignalSince = nil
        }
    }

    private func dropRoute(reason: String? = nil) {
        stopTimers()
        route?.stop()
        route = nil
        phase = .idle
        runningWithZeroSignalSince = nil
        message = reason
        shortcuts = false
        hotkeys.unregister()
        syncMediaKeyIntercept()
    }

    private func syncMediaKeyIntercept() {
        // Yield backup Engine tap whenever the main UI app is running its own active MediaKeyTap.
        if uiHandlesMediaKeys {
            let uiStillAlive = !NSRunningApplication.runningApplications(withBundleIdentifier: VolumeIPC.suiteName).isEmpty
            if uiStillAlive {
                mediaKeyTap.shouldIntercept = false
                mediaKeysActive = true
                return
            } else {
                uiHandlesMediaKeys = false
            }
        }
        let trusted = MediaKeyTap.isAccessibilityTrusted
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
        retryAfter = ProcessInfo.processInfo.systemUptime + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.evaluateRoute()
            self?.publishState(writeDisk: false)
        }
    }

    private func updateAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        guard !MediaKeyTap.isAccessibilityTrusted else { return }
        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(onAccessibilityPoll), userInfo: nil, repeats: true)
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPollTimer = timer
    }

    @objc private func onCheckTick() {
        evaluateCheckingSignal()
    }

    @objc private func onWatchdogTick() {
        guard !sleeping, phase == .active, let route else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let latest = route.callbackCount
        if latest != callbackCount {
            callbackCount = latest
            lastCallbackTime = now
        } else if now - lastCallbackTime > 3.5 {
            dropRoute(reason: L10n.text("音频通道暂时中断，正在重新连接…", "Audio stream interrupted, reconnecting…"))
            scheduleRetry(after: 1.5)
            publishState(writeDisk: false)
        }
    }

    @objc private func onAccessibilityPoll() {
        guard MediaKeyTap.isAccessibilityTrusted else { return }
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        syncMediaKeyIntercept()
        publishState(writeDisk: true)
    }

    private func publishState(writeDisk: Bool) {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        let state = VolumeState(
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
            mediaKeysActive: (uiHandlesMediaKeys || (trusted && mediaKeyTap.isRunning)),
            shortcutsAvailable: shortcuts,
            showOSD: showOSD,
            showMenuBarPercent: showMenuBarPercent,
            scrollOnIconEnabled: scrollOnIconEnabled,
            lastTriggerSource: lastTriggerSource,
            lastTriggerNonce: lastTriggerNonce,
            message: message
        )
        if state != lastPublishedState {
            lastPublishedState = state
            VolumeIPC.publish(state, writeDisk: writeDisk, notify: true)
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
