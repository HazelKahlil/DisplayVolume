import AppKit
import Carbon

@MainActor
final class Hotkeys {
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    private var localMonitor: Any?
    private let action: (UInt32) -> Void
    private static let signature: UInt32 = 0x44564F4C // 'DVOL'

    init(action: @escaping (UInt32) -> Void) {
        self.action = action
    }

    func register() -> Bool {
        unregister()
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
                unregister()
                return false
            }
            keys.append(key)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard flags == [.control, .option] else { return event }
            let code = Int(event.keyCode)
            let repeatPress = event.isARepeat
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                switch code {
                case kVK_UpArrow: self.action(1)
                case kVK_DownArrow: self.action(2)
                case kVK_ANSI_M: if !repeatPress { self.action(3) }
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
        return true
    }

    func unregister() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        for key in keys { UnregisterEventHotKey(key) }
        keys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
