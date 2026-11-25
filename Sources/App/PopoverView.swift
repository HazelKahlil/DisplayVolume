import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: VolumeController
    let onHideIcon: () -> Void
    let onQuitAll: () -> Void
    let sizeChanged: (CGSize) -> Void

    @State private var showsSettings = false
    @State private var showsVirtualOutputs = false
    @State private var showsVirtualInputs = false
    @State private var launchUIAtLogin = (SMAppService.mainApp.status == .enabled)

    private var physicalOutputs: [AudioDeviceInfo] {
        model.outputDevices.filter { $0.isPhysicalOutput || $0.uid == model.deviceUID }
    }

    private var virtualOutputs: [AudioDeviceInfo] {
        model.outputDevices.filter { !$0.isPhysicalOutput && $0.uid != model.deviceUID }
    }

    private var physicalInputs: [AudioDeviceInfo] {
        model.inputDevices.filter { $0.isPhysicalInput || $0.uid == model.currentInputDevice?.uid }
    }

    private var virtualInputs: [AudioDeviceInfo] {
        model.inputDevices.filter { !$0.isPhysicalInput && $0.uid != model.currentInputDevice?.uid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Primary Sound Output Control (Software on locked displays + Native hardware on built-in/AirPods)
            outputControlSection

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

            // 2. Output Devices (Directly visible)
            outputDevicesSection

            Divider().opacity(0.32)

            // 3. Input / Microphone Control & Devices (Directly visible)
            inputSection

            // 4. Minimal keyboard permission row (only when Accessibility is missing on locked monitor)
            if model.isEngineConnected && model.isControllable && model.isEnabled && !model.mediaKeysAuthorized {
                compactKeyboardPermissionRow
            }

            if showsSettings {
                settingsSection
            }

            Divider().opacity(0.32)

            // 5. Footer Bar
            footerBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 312)
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: sizeChanged)
        .onAppear {
            model.refreshIfStale()
            model.refreshAccessibilityState()
            launchUIAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - 1. Output Sound & Ceiling Control

    @ViewBuilder
    private var outputControlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("输出声音", "Output"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.canControlCurrentOutput {
                    Text(model.effectiveOutputMuted ? L10n.mutedLabel : "\(model.effectiveOutputVolume)%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(model.effectiveOutputMuted ? .secondary : .primary)
                        .contentTransition(.numericText())
                        .accessibilityLabel(L10n.text("输出音量百分之\(model.effectiveOutputVolume)", "Output volume \(model.effectiveOutputVolume) percent"))
                } else if model.isEngineConnected {
                    Text(outputModeBadgeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !model.isEngineConnected && model.isControllable {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在连接音量后台…", "Connecting to audio engine…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if model.phase == .checking && model.isControllable {
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
            } else if model.canControlCurrentOutput {
                // Main native volume slider row (handles both software monitor & native hardware speakers)
                HStack(spacing: 8) {
                    Button {
                        model.toggleActiveOutputMute()
                    } label: {
                        Image(systemName: model.effectiveOutputMuted || model.effectiveOutputVolume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.effectiveOutputMuted ? .primary : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(model.effectiveOutputMuted ? L10n.text("恢复声音", "Unmute") : L10n.text("静音", "Mute"))
                    .accessibilityLabel(model.effectiveOutputMuted ? L10n.text("恢复声音", "Unmute") : L10n.text("静音", "Mute"))

                    SmoothNativeSlider(
                        value: model.effectiveOutputMuted ? 0 : model.effectiveOutputVolume,
                        minValue: 0,
                        maxValue: model.effectiveOutputLimit,
                        accessibilityTitle: L10n.text("输出音量", "Output Volume")
                    ) { pct, isTracking in
                        model.setActiveOutputVolume(pct, isDragging: isTracking)
                    }

                    Button {
                        model.setActiveOutputVolume(model.effectiveOutputLimit)
                    } label: {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("调到上限 (\(model.effectiveOutputLimit)%)", "Set to \(model.effectiveOutputLimit)%"))
                }

                // Compact neutral presets
                let limit = model.effectiveOutputLimit
                HStack(spacing: 6) {
                    ForEach([25, 50, 75].filter { $0 < limit }, id: \.self) { preset in
                        let isSelected = !model.effectiveOutputMuted && model.effectiveOutputVolume == preset
                        GlassCapsuleButton(selected: isSelected) {
                            model.setActiveOutputVolume(preset)
                        } label: {
                            Text("\(preset)%")
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular).monospacedDigit())
                                .frame(maxWidth: .infinity)
                        }
                    }
                    let isAtLimit = !model.effectiveOutputMuted && model.effectiveOutputVolume == limit
                    GlassCapsuleButton(selected: isAtLimit) {
                        model.setActiveOutputVolume(limit)
                    } label: {
                        Text(limit < 100 ? "\(limit)%" : (model.isSoftwareOutputActive ? L10n.maxButton : "100%"))
                            .font(.system(size: 10.5, weight: isAtLimit ? .semibold : .regular).monospacedDigit())
                            .frame(maxWidth: .infinity)
                    }
                }

                // Directly visible Safety Ceiling row (for locked external display software attenuation)
                if model.isSoftwareOutputActive {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.maxVolumeTitle)
                                .font(.system(size: 11, weight: .medium))
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
                                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
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
                    .padding(.top, 1)
                }
            } else if model.isControllable && model.isEnabled {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在重新连接外接音频…", "Reconnecting external audio…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
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
                Text(L10n.text("当前虚拟输出不支持音量滑块。", "Selected output does not expose volume controls."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputModeBadgeText: String {
        if model.phase == .checking { return L10n.text("等待授权", "Verifying") }
        if model.isControllable && model.isEnabled { return L10n.text("重连中", "Reconnecting") }
        if model.isControllable { return L10n.pausedBadge }
        return L10n.nativeControlBadge
    }

    // MARK: - 2. Directly Visible Output Devices

    private var outputDevicesSection: some View {
        let visibleList = showsVirtualOutputs ? (physicalOutputs + virtualOutputs) : physicalOutputs
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text("输出设备", "Output Devices"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !virtualOutputs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            showsVirtualOutputs.toggle()
                        }
                    } label: {
                        Text(showsVirtualOutputs
                            ? L10n.text("隐藏虚拟设备", "Hide Virtual")
                            : L10n.text("虚拟设备 (\(virtualOutputs.count))", "Virtual (\(virtualOutputs.count))"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            deviceListContainer(items: visibleList) { dev in
                outputDeviceRow(dev)
            }
        }
    }

    private func outputDeviceRow(_ dev: AudioDeviceInfo) -> some View {
        let isCurrent = dev.uid == model.deviceUID
        return deviceRow(
            title: dev.name,
            subtitle: outputDeviceHint(dev, isCurrent: isCurrent),
            symbol: dev.symbolName(forInput: false),
            isCurrent: isCurrent
        ) {
            model.selectOutputDevice(uid: dev.uid)
        }
    }

    private func outputDeviceHint(_ dev: AudioDeviceInfo, isCurrent: Bool) -> String {
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

    // MARK: - 3. Input / Microphone Control & Devices

    private var inputSection: some View {
        let visibleInputs = showsVirtualInputs ? (physicalInputs + virtualInputs) : physicalInputs
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("输入（麦克风）", "Input (Microphone)"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.currentInputDevice != nil {
                    if model.inputMuted {
                        Text(L10n.micMutedLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else if model.inputVolumeWritable {
                        Text("\(model.shownInputVolume)%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                            .accessibilityLabel(L10n.text("麦克风音量百分之\(model.shownInputVolume)", "Microphone volume \(model.shownInputVolume) percent"))
                    } else {
                        Text(L10n.autoGainLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.currentInputDevice == nil {
                Text(L10n.text("未检测到可用麦克风。", "No input device detected."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if model.inputVolumeWritable || model.inputMuteSupported {
                HStack(spacing: 8) {
                    Button {
                        model.toggleInputMute(showOSD: false)
                    } label: {
                        Image(systemName: model.inputMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.inputMuted ? .primary : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.inputMuteSupported)
                    .help(model.inputMuted
                        ? L10n.text("取消静音麦克风 (⌃⌥⇧ M)", "Unmute Microphone (⌃⌥⇧ M)")
                        : L10n.text("静音麦克风 (⌃⌥⇧ M)", "Mute Microphone (⌃⌥⇧ M)"))
                    .accessibilityLabel(model.inputMuted ? L10n.text("取消静音麦克风", "Unmute Microphone") : L10n.text("静音麦克风", "Mute Microphone"))

                    if model.inputVolumeWritable {
                        SmoothNativeSlider(
                            value: model.shownInputVolume,
                            minValue: 0,
                            maxValue: 100,
                            accessibilityTitle: L10n.text("麦克风音量", "Microphone Volume")
                        ) { pct, isTracking in
                            model.setInputVolume(pct, isDragging: isTracking)
                        }
                    } else {
                        Text(model.inputMuted
                            ? L10n.text("麦克风已静音", "Microphone muted")
                            : L10n.text("该设备不支持手动增益调节", "Manual gain unavailable"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                Text(L10n.text("该麦克风由系统自动管理增益，不支持手动静音或调节。", "This microphone manages gain automatically and does not expose system mute."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.text("输入设备", "Input Devices"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !virtualInputs.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                showsVirtualInputs.toggle()
                            }
                        } label: {
                            Text(showsVirtualInputs
                                ? L10n.text("隐藏虚拟设备", "Hide Virtual")
                                : L10n.text("虚拟设备 (\(virtualInputs.count))", "Virtual (\(virtualInputs.count))"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                deviceListContainer(items: visibleInputs) { dev in
                    inputDeviceRow(dev)
                }
            }
        }
    }

    private func inputDeviceRow(_ dev: AudioDeviceInfo) -> some View {
        let isCurrent = dev.uid == model.currentInputDevice?.uid
        return deviceRow(
            title: dev.name,
            subtitle: inputDeviceHint(dev, isCurrent: isCurrent),
            symbol: dev.symbolName(forInput: true),
            isCurrent: isCurrent
        ) {
            model.selectInputDevice(uid: dev.uid)
        }
    }

    private func inputDeviceHint(_ dev: AudioDeviceInfo, isCurrent: Bool) -> String {
        let mode: String
        if dev.transportKind.isVirtualOrAggregate {
            mode = L10n.virtualBadge
        } else if isCurrent && model.inputMuted {
            mode = L10n.micMutedLabel
        } else if dev.inputVolumeControlAvailable {
            mode = L10n.text("支持增益与静音", "Gain & Mute")
        } else if dev.inputMuteControlAvailable {
            mode = L10n.text("支持静音", "Mute Only")
        } else {
            mode = L10n.autoGainLabel
        }
        return "\(dev.transportKind.displayLabel) · \(mode)"
    }

    // MARK: - Shared Device Row & Bounded List

    @ViewBuilder
    private func deviceListContainer<Row: View>(
        items: [AudioDeviceInfo],
        @ViewBuilder row: @escaping (AudioDeviceInfo) -> Row
    ) -> some View {
        if items.count > 3 {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 3) {
                    ForEach(items) { dev in row(dev) }
                }
            }
            .frame(maxHeight: 118)
        } else {
            VStack(spacing: 3) {
                ForEach(items) { dev in row(dev) }
            }
        }
    }

    private func deviceRow(
        title: String,
        subtitle: String,
        symbol: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? Color.primary : Color.primary.opacity(0.08))
                        .frame(width: 24, height: 24)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCurrent ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 0.5) {
                    Text(title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.primary.opacity(0.075) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4. Compact Keyboard Permission Row

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

    // MARK: - 5. Preferences Drawer

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

            Text(L10n.text("快捷键：F10–F12 · ⇧⌥ 微调 · ⌃⌥⇧ M 麦克风静音", "Keys: F10–F12 · ⇧⌥ Fine · ⌃⌥⇧ M Mic Mute"))
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

    // MARK: - 6. Footer

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
