import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: VolumeController
    let onHideIcon: () -> Void
    let onQuitAll: () -> Void
    let sizeChanged: (CGSize) -> Void

    @State private var showsSettings = false
    @State private var showsVirtualDevices = false
    @State private var launchUIAtLogin = (SMAppService.mainApp.status == .enabled)

    private var physicalDevices: [AudioDeviceInfo] {
        model.outputDevices.filter { $0.isPhysicalOutput || $0.uid == model.deviceUID }
    }

    private var virtualDevices: [AudioDeviceInfo] {
        model.outputDevices.filter { !$0.isPhysicalOutput && $0.uid != model.deviceUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Primary Sound Control (Native Control Center layout — always directly visible)
            soundControlSection

            if let message = model.message {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Divider().opacity(0.32)

            // 2. Output Devices (Directly visible like macOS native Control Center Sound panel)
            outputDevicesSection

            // 3. Minimal unobtrusive keyboard permission row (only shown when Accessibility is missing)
            if model.isEngineConnected && model.isControllable && model.isEnabled && !model.mediaKeysAuthorized {
                compactKeyboardPermissionRow
            }

            if showsSettings {
                settingsSection
            }

            Divider().opacity(0.32)

            // 4. Footer Bar
            footerBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300)
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: sizeChanged)
        .onAppear {
            model.refreshOutputDevices()
            model.refreshAccessibilityState()
            launchUIAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - 1. Native Sound & Ceiling Sliders

    @ViewBuilder
    private var soundControlSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("声音", "Sound"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.phase == .active {
                    Text(model.muted ? L10n.mutedLabel : "\(model.shownVolume)%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(model.muted ? .secondary : .primary)
                        .contentTransition(.numericText())
                        .accessibilityLabel(L10n.text("音量百分之\(model.shownVolume)", "Volume \(model.shownVolume) percent"))
                } else if model.isEngineConnected {
                    Text(modeBadgeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !model.isEngineConnected {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在连接音量后台…", "Connecting to audio engine…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if model.phase == .checking {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        ProgressView().controlSize(.small).padding(.top, 1)
                        Text(L10n.text("播放任意声音以完成首次系统音频授权，验证一次后即永久生效。", "Play any audio once to verify capture permission."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        GlassCapsuleButton {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(L10n.text("打开音频权限设置", "Open Audio Privacy"))
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                }
            } else if model.phase == .active {
                // Main native volume slider row
                HStack(spacing: 8) {
                    Button {
                        model.toggleMute()
                    } label: {
                        Image(systemName: model.muted || model.shownVolume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.muted ? .primary : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(model.muted ? L10n.text("恢复声音", "Unmute") : L10n.text("静音", "Mute"))
                    .accessibilityLabel(model.muted ? L10n.text("恢复声音", "Unmute") : L10n.text("静音", "Mute"))

                    SmoothNativeSlider(
                        value: model.muted ? 0 : model.shownVolume,
                        minValue: 0,
                        maxValue: model.volumeLimit,
                        accessibilityTitle: L10n.text("软件音量", "Software Volume")
                    ) { pct, isTracking in
                        model.setVolume(pct, isDragging: isTracking)
                    }

                    Button {
                        model.setVolume(model.volumeLimit)
                    } label: {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("调到当前安全上限 (\(model.volumeLimit)%)", "Set to ceiling (\(model.volumeLimit)%)"))
                }

                // Compact neutral preset row
                HStack(spacing: 6) {
                    ForEach([25, 50, 75].filter { $0 < model.volumeLimit }, id: \.self) { preset in
                        let isSelected = !model.muted && model.shownVolume == preset
                        GlassCapsuleButton(selected: isSelected) {
                            model.setVolume(preset)
                        } label: {
                            Text("\(preset)%")
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular).monospacedDigit())
                                .frame(maxWidth: .infinity)
                        }
                    }
                    let isAtLimit = !model.muted && model.shownVolume == model.volumeLimit
                    GlassCapsuleButton(selected: isAtLimit) {
                        model.setVolume(model.volumeLimit)
                    } label: {
                        Text(model.volumeLimit < 100 ? "\(model.volumeLimit)%" : L10n.maxButton)
                            .font(.system(size: 10.5, weight: isAtLimit ? .semibold : .regular).monospacedDigit())
                            .frame(maxWidth: .infinity)
                    }
                }

                // Directly visible Safety Ceiling row (no click required!)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.maxVolumeTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.volumeLimit < 100 {
                            Button(L10n.text("恢复 100%", "Reset")) {
                                model.setVolumeLimit(100)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                        }
                        Text("\(model.volumeLimit)%")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    SmoothNativeSlider(
                        value: model.volumeLimit,
                        minValue: 1,
                        maxValue: 100,
                        accessibilityTitle: L10n.maxVolumeTitle
                    ) { cap, isTracking in
                        model.setVolumeLimit(max(1, cap), isDragging: isTracking)
                    }
                }
                .padding(.top, 2)
            } else if model.isControllable {
                HStack {
                    Text(L10n.text("软件音量已暂停，音箱保持原声输出。", "Software volume is paused."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    GlassCapsuleButton(selected: true) {
                        model.enable()
                    } label: {
                        Text(L10n.text("启用", "Enable"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text(L10n.text("当前设备由 macOS 原生控制，音量键直接放行。", "Current output uses native macOS volume control."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeBadgeText: String {
        if model.phase == .checking { return L10n.text("等待授权", "Verifying") }
        if model.isControllable { return L10n.pausedBadge }
        return L10n.nativeControlBadge
    }

    // MARK: - 2. Directly Visible Output Devices

    private var outputDevicesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("输出", "Output"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !virtualDevices.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            showsVirtualDevices.toggle()
                        }
                    } label: {
                        Text(showsVirtualDevices
                            ? L10n.text("隐藏虚拟设备", "Hide Virtual")
                            : L10n.text("虚拟设备 (\(virtualDevices.count))", "Virtual (\(virtualDevices.count))"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            let visibleList = showsVirtualDevices ? (physicalDevices + virtualDevices) : physicalDevices
            ForEach(visibleList) { dev in
                outputDeviceRow(dev)
            }
        }
    }

    private func outputDeviceRow(_ dev: AudioDeviceInfo) -> some View {
        let isCurrent = dev.uid == model.deviceUID
        return Button {
            model.selectOutputDevice(uid: dev.uid)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? Color.primary : Color.primary.opacity(0.08))
                        .frame(width: 24, height: 24)
                    Image(systemName: dev.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCurrent ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 0.5) {
                    Text(dev.name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(deviceModeHint(dev, isCurrent: isCurrent))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.primary.opacity(0.075) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deviceModeHint(_ dev: AudioDeviceInfo, isCurrent: Bool) -> String {
        let mode: String
        if dev.isAutoControllable {
            mode = isCurrent && model.phase == .active
                ? L10n.activeControlBadge
                : L10n.text("支持软件控音", "Software Ready")
        } else if dev.transportKind.isVirtualOrAggregate {
            mode = L10n.virtualBadge
        } else {
            mode = L10n.nativeControlBadge
        }
        return "\(dev.transportKind.displayLabel) · \(mode)"
    }

    // MARK: - 3. Compact Keyboard Permission Row (Monochrome, Single Line)

    private var compactKeyboardPermissionRow: some View {
        Button {
            model.requestAccessibility()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(L10n.text("授权后可用键盘 F10–F12 直接调音", "Allow Accessibility for F10–F12 media keys"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(L10n.text("开启", "Allow"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.11), in: Capsule())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4. Preferences Drawer

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(L10n.text("菜单栏显示音量百分比", "Show % in menu bar"), isOn: Binding(
                get: { model.showMenuBarPercent },
                set: { model.setShowMenuBarPercent($0) }
            ))
            Toggle(L10n.text("按键/滚轮调节时显示屏幕浮窗", "Show floating volume OSD"), isOn: Binding(
                get: { model.showOSD },
                set: { model.setShowOSD($0) }
            ))
            Toggle(L10n.text("滚轮悬停菜单栏图标调音量", "Scroll menu bar icon to adjust"), isOn: Binding(
                get: { model.scrollOnIconEnabled },
                set: { model.setScrollOnIcon($0) }
            ))
            Toggle(L10n.text("开机自动启动菜单栏界面", "Launch menu bar icon at login"), isOn: Binding(
                get: { launchUIAtLogin },
                set: { wantOn in
                    do {
                        if wantOn { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {}
                    launchUIAtLogin = (SMAppService.mainApp.status == .enabled)
                }
            ))

            Text(L10n.text("快捷键：F10–F12 · ⇧⌥ 微调 · ⌃⌥ ↑/↓/M", "Keys: F10–F12 · ⇧⌥ Fine · ⌃⌥ ↑/↓/M"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11))
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 5. Footer

    private var footerBar: some View {
        HStack(spacing: 8) {
            if model.isEngineConnected && model.isControllable {
                GlassCapsuleButton {
                    if model.isEnabled { model.disable() }
                    else { model.enable() }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.isEnabled ? Color.green.opacity(0.85) : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                        Text(model.isEnabled ? L10n.text("控音中", "Active") : L10n.text("已暂停", "Paused"))
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .help(model.isEnabled
                    ? L10n.text("暂停软件音量并恢复硬件原声", "Pause software volume")
                    : L10n.text("恢复软件音量控制", "Resume software volume"))
            } else {
                Text(L10n.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            GlassCircleButton(
                active: showsSettings,
                helpText: L10n.text("偏好设置", "Preferences")
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsSettings.toggle()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10.5, weight: .medium))
            }

            GlassCircleButton(
                helpText: L10n.text("退出选项", "Quit Options")
            ) {
                presentPowerMenu()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10.5, weight: .medium))
            }
        }
    }

    private func presentPowerMenu() {
        let menu = NSMenu()
        let hideItem = NSMenuItem(
            title: L10n.text("隐藏图标（后台继续控音）", "Hide Icon (Keep Engine Running)"),
            action: #selector(PowerMenuTarget.hideIcon),
            keyEquivalent: ""
        )
        let quitItem = NSMenuItem(
            title: L10n.text("完全退出并停用后台", "Quit & Stop Background Engine"),
            action: #selector(PowerMenuTarget.quitAll),
            keyEquivalent: ""
        )
        let target = PowerMenuTarget(onHideIcon: onHideIcon, onQuitAll: onQuitAll)
        hideItem.target = target
        quitItem.target = target
        objc_setAssociatedObject(menu, &PowerMenuTarget.assocKey, target, .OBJC_ASSOCIATION_RETAIN)
        menu.addItem(hideItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        if let event = NSApp.currentEvent, let view = NSApp.keyWindow?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }
}

@MainActor
private final class PowerMenuTarget: NSObject {
    nonisolated(unsafe) static var assocKey: UInt8 = 0
    let onHideIcon: () -> Void
    let onQuitAll: () -> Void

    init(onHideIcon: @escaping () -> Void, onQuitAll: @escaping () -> Void) {
        self.onHideIcon = onHideIcon
        self.onQuitAll = onQuitAll
    }

    @objc func hideIcon() { onHideIcon() }
    @objc func quitAll() { onQuitAll() }
}
