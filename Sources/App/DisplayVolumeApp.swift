import AppKit
import CoreAudio
import CryptoKit
import OSLog
import SwiftUI

@MainActor
final class VolumeController: NSObject, ObservableObject {
    @Published private(set) var state = VolumeIPC.read()
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var uiAccessibilityTrusted = MediaKeyTap.isAccessibilityTrusted

    @Published private var optimisticVolume: Int?
    @Published private var optimisticLimit: Int?
    @Published private var optimisticMuted: Bool?

    private var volumeLockUntil: TimeInterval = 0
    private var limitLockUntil: TimeInterval = 0
    private var isDraggingVolume = false
    private var isDraggingLimit = false
    private var lastVolumeIPCSentAt: TimeInterval = 0
    private var lastLimitIPCSentAt: TimeInterval = 0

    private var heartbeat: Timer?
    private var axPollTimer: Timer?
    private var scrollAccumulator: CGFloat = 0
    var onChange: (() -> Void)?

    private lazy var uiMediaKeyTap = MediaKeyTap { [weak self] action in
        self?.handleMediaKeyAction(action)
    }

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
    var deviceUID: String? { state?.deviceUID }
    var deviceName: String? { state?.deviceName }
    var transportLabel: String? { state?.transportLabel }
    var isEngineConnected: Bool { state != nil }
    var isControllable: Bool { state?.isControllable ?? false }
    var isEnabled: Bool { state?.enabled ?? false }

    func beginMonitoring() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStateNotification(_:)),
            name: VolumeIPC.changed,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        let timer = Timer(timeInterval: 5.0, target: self, selector: #selector(pollFallback), userInfo: nil, repeats: true)
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        refreshOutputDevices()
        syncUIMediaKeyTap()
    }

    func shutDown() {
        heartbeat?.invalidate()
        heartbeat = nil
        axPollTimer?.invalidate()
        axPollTimer = nil
        if uiMediaKeyTap.isRunning {
            VolumeIPC.send(.setUIMediaKeysActive, flag: false)
        }
        uiMediaKeyTap.stop()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func refreshOutputDevices() {
        outputDevices = OutputDeviceCatalog.allOutputDevices()
    }

    func refreshAccessibilityState() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        if trusted != uiAccessibilityTrusted {
            uiAccessibilityTrusted = trusted
            onChange?()
        }
        syncUIMediaKeyTap()
    }

    func selectOutputDevice(uid: String) {
        if OutputDeviceCatalog.setDefaultOutput(uid: uid) {
            refreshOutputDevices()
        }
    }

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
            optimisticVolume = nil
            optimisticMuted = nil
        }
        if !isDraggingLimit && now >= limitLockUntil {
            optimisticLimit = nil
        }

        if state != latest {
            state = latest
            syncUIMediaKeyTap()
            if uiMediaKeyTap.isRunning, latest?.mediaKeysActive == false {
                VolumeIPC.send(.setUIMediaKeysActive, flag: true)
            }
            onChange?()
        }
    }

    func refreshFromDisk() {
        applyIncomingState(VolumeIPC.read())
    }

    @objc private func pollFallback() {
        refreshFromDisk()
        refreshAccessibilityState()
    }

    private func syncUIMediaKeyTap() {
        let trusted = MediaKeyTap.isAccessibilityTrusted
        uiAccessibilityTrusted = trusted
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
        guard scrollOnIconEnabled, phase == .active else { return }
        scrollAccumulator += deltaY
        let stepThreshold: CGFloat = 4.0
        guard abs(scrollAccumulator) >= stepThreshold else { return }
        let steps = Int((scrollAccumulator / stepThreshold).rounded(.towardZero))
        scrollAccumulator -= CGFloat(steps) * stepThreshold
        if steps != 0 {
            VolumeIPC.send(.step, value: steps * 2, source: .scroll)
        }
    }

    func enable() { VolumeIPC.send(.enable) }
    func disable() { VolumeIPC.send(.pause) }

    func setVolume(_ percent: Int, isDragging: Bool = false) {
        let clamped = VolumeMath.clampedVolume(percent, limit: volumeLimit)
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingVolume = isDragging
        volumeLockUntil = now + 0.30
        if clamped > 0 {
            optimisticVolume = clamped
            optimisticMuted = false
        } else {
            optimisticMuted = true
        }
        onChange?()

        if !isDragging || (now - lastVolumeIPCSentAt) >= 0.025 {
            lastVolumeIPCSentAt = now
            VolumeIPC.send(.volume, value: clamped, source: .slider)
        }
    }

    func setVolumeLimit(_ percent: Int, isDragging: Bool = false) {
        let clamped = min(100, max(1, percent))
        let now = ProcessInfo.processInfo.systemUptime
        isDraggingLimit = isDragging
        limitLockUntil = now + 0.30
        optimisticLimit = clamped
        if let v = optimisticVolume, v > clamped {
            optimisticVolume = clamped
        }
        onChange?()

        if !isDragging || (now - lastLimitIPCSentAt) >= 0.025 {
            lastLimitIPCSentAt = now
            VolumeIPC.send(.limit, value: clamped)
        }
    }

    func toggleMute() {
        let now = ProcessInfo.processInfo.systemUptime
        volumeLockUntil = now + 0.25
        optimisticMuted = !muted
        onChange?()
        VolumeIPC.send(.mute, source: .slider)
    }

    func requestAccessibility() {
        // Request permission on the main user-facing app ("桌面音量") so the user sees it directly in Applications.
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
    private let model = VolumeController()
    private let log = Logger(subsystem: VolumeIPC.suiteName, category: "DisplayVolumeUI")
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var scrollMonitor: Any?
    private var sleepObserver: NSObjectProtocol?

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTestSuite()
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
            let devices = OutputDeviceCatalog.allOutputDevices()
            let current = OutputDeviceCatalog.currentDefault()
            print("Default output: \(current?.name ?? "None") (\(current?.transportKind.displayLabel ?? "-"))")
            print("Native scalar volume available: \(current?.volumeControlAvailable ?? false)")
            print("Auto-controllable: \(current?.isAutoControllable ?? false)")
            print("UI Accessibility trusted: \(MediaKeyTap.isAccessibilityTrusted)")
            print("All outputs (\(devices.count)):")
            for dev in devices {
                print("  - \(dev.name) [\(dev.transportKind.displayLabel)] controllable=\(dev.isAutoControllable)")
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
        EngineProvisioner.ensureInstalledAndRunning()

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
        popover.contentSize = NSSize(width: 300, height: 320)

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

        if CommandLine.arguments.contains("--open-popover") || model.phase != .active {
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
            model.refreshOutputDevices()
            model.refreshAccessibilityState()
            showPopover()
        }
    }

    private func showQuickContextMenu(_ button: NSStatusBarButton) {
        closePopover()
        let menu = NSMenu()
        if model.phase == .active {
            let muteTitle = model.muted ? L10n.text("取消静音", "Unmute") : L10n.text("静音", "Mute")
            let muteItem = NSMenuItem(title: muteTitle, action: #selector(menuToggleMute), keyEquivalent: "")
            muteItem.target = self
            menu.addItem(muteItem)
        }
        if model.isControllable {
            let toggleTitle = model.isEnabled ? L10n.text("暂停软件音量", "Pause Software Volume") : L10n.text("启用软件音量", "Enable Software Volume")
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

    @objc private func menuToggleMute() { model.toggleMute() }
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
        let label = model.phase == .active
            ? (model.muted ? L10n.mutedLabel : "\(L10n.appName) \(model.shownVolume)%")
            : L10n.appName
        let image = MenuBarIconRenderer.makeIcon(
            volume: model.shownVolume,
            muted: model.muted,
            active: model.phase == .active
        )
        button.image = image
        button.imagePosition = model.showMenuBarPercent && model.phase == .active ? .imageLeading : .imageOnly
        if model.showMenuBarPercent && model.phase == .active {
            let text = model.muted ? L10n.mutedLabel : "\(model.shownVolume)%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            ]
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attrs)
        } else {
            button.title = ""
        }
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }
}

private func runSelfTestSuite() {
    let clamped1 = VolumeMath.clampedVolume(95, limit: 80) == 80
    let clamped2 = VolumeMath.clampedVolume(-5, limit: 80) == 0
    let step1 = VolumeMath.applyStep(currentVolume: 60, limit: 80, muted: false, delta: 5) == (65, false)
    let step2 = VolumeMath.applyStep(currentVolume: 78, limit: 80, muted: false, delta: 5) == (80, false)
    let step3 = VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: false, delta: -5) == (3, true)
    let step4 = VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: true, delta: 5) == (3, false)
    let step5 = VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: -5) == (40, true)

    let ok = clamped1 && clamped2 && step1 && step2 && step3 && step4 && step5
    print(ok ? "PASS app volume math tests" : "FAIL app volume math tests")
    exit(ok ? 0 : 1)
}
