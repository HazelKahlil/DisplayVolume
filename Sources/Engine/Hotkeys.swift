import AppKit
import Carbon

@MainActor
final class Hotkeys {
    private var handler: EventHandlerRef?
    private var outputKeys: [EventHotKeyRef] = []
    private var micKey: EventHotKeyRef?
    private var localMonitor: Any?
    private let action: (UInt32) -> Void
    private static let signature: UInt32 = 0x44564F4C // 'DVOL'

    private(set) var outputHotkeysRegistered = false
    private(set) var micHotkeyRegistered = false

    init(action: @escaping (UInt32) -> Void) {
        self.action = action
    }

    private func ensureHandlerInstalled() -> Bool {
        if handler != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var hotkey = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkey
            )
            guard status == noErr, hotkey.signature == 0x44564F4C else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Hotkeys>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { owner.action(hotkey.id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
                let code = Int(event.keyCode)
                let repeatPress = event.isARepeat
                let handled = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if self.outputHotkeysRegistered, flags == [.control, .option] {
                        switch code {
                        case kVK_UpArrow: self.action(1)
                        case kVK_DownArrow: self.action(2)
                        case kVK_ANSI_M: if !repeatPress { self.action(3) }
                        default: return false
                        }
                        return true
                    }
                    if self.micHotkeyRegistered, flags == [.control, .option, .shift], code == kVK_ANSI_M {
                        if !repeatPress { self.action(4) }
                        return true
                    }
                    return false
                }
                return handled ? nil : event
            }
        }
        return true
    }

    /// Registers global `⌃⌥⇧ M` microphone mute toggle (remains active regardless of output device).
    @discardableResult
    func registerMicMute() -> Bool {
        guard ensureHandlerInstalled() else {
            micHotkeyRegistered = false
            return false
        }
        if micKey != nil {
            micHotkeyRegistered = true
            return true
        }
        var key: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(controlKey | optionKey | shiftKey),
            EventHotKeyID(signature: Self.signature, id: 4),
            GetApplicationEventTarget(),
            0,
            &key
        )
        guard status == noErr, let key else {
            micHotkeyRegistered = false
            return false
        }
        micKey = key
        micHotkeyRegistered = true
        return true
    }

    /// Registers output volume hotkeys (`⌃⌥ ↑ / ↓ / M`) while software volume control is active.
    func register() -> Bool {
        unregisterOutput()
        guard ensureHandlerInstalled() else { return false }

        for (code, id) in [(kVK_UpArrow, 1), (kVK_DownArrow, 2), (kVK_ANSI_M, 3)] {
            var key: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(code),
                UInt32(controlKey | optionKey),
                EventHotKeyID(signature: Self.signature, id: UInt32(id)),
                GetApplicationEventTarget(),
                0,
                &key
            )
            guard status == noErr, let key else {
                unregisterOutput()
                return false
            }
            outputKeys.append(key)
        }
        outputHotkeysRegistered = true
        return true
    }

    func unregisterOutput() {
        for key in outputKeys { UnregisterEventHotKey(key) }
        outputKeys.removeAll()
        outputHotkeysRegistered = false
    }

    func unregisterAll() {
        unregisterOutput()
        if let micKey { UnregisterEventHotKey(micKey) }
        micKey = nil
        micHotkeyRegistered = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
