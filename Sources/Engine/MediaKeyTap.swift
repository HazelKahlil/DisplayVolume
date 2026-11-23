import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import os

enum MediaKeyAction: Equatable {
    case volumeUp(fine: Bool)
    case volumeDown(fine: Bool)
    case toggleMute
}

enum MediaKeyParser {
    static let systemDefinedTypeRawValue: UInt32 = 14 // NX_SYSDEFINED
    static let auxControlSubtype: Int16 = Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS)
    static let soundUpKey: Int = Int(NX_KEYTYPE_SOUND_UP)
    static let soundDownKey: Int = Int(NX_KEYTYPE_SOUND_DOWN)
    static let muteKey: Int = Int(NX_KEYTYPE_MUTE)

    struct ParsedEvent: Equatable {
        let action: MediaKeyAction
        let isKeyDown: Bool
        let isRepeat: Bool
    }

    /// Parses an `NX_SYSDEFINED` subtype-8 keyboard media event. Returns nil for non-volume keys
    /// or modifier combinations that belong to macOS (e.g. Option+Volume opens Sound Settings).
    static func parse(subtype: Int16, data1: Int, modifierFlags: NSEvent.ModifierFlags) -> ParsedEvent? {
        guard subtype == auxControlSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isRepeat = (keyFlags & 0x1) != 0

        let isKeyDown: Bool
        switch keyState {
        case 0x0A: isKeyDown = true
        case 0x0B: isKeyDown = false
        default: return nil
        }

        let mods = modifierFlags.intersection([.shift, .control, .option, .command])
        // Pass Command/Control shortcuts and pure Option+Volume (opens Sound Settings) straight through.
        if mods.contains(.command) || mods.contains(.control) || mods == [.option] {
            return nil
        }
        let fine = mods.contains(.shift) && mods.contains(.option)

        let action: MediaKeyAction
        switch keyCode {
        case soundUpKey: action = .volumeUp(fine: fine)
        case soundDownKey: action = .volumeDown(fine: fine)
        case muteKey: action = .toggleMute
        default: return nil
        }

        return ParsedEvent(action: action, isKeyDown: isKeyDown, isRepeat: isRepeat)
    }
}

/// Thread-isolated CGEventTap for hardware Magic Keyboard / MacBook F10-F12 volume keys.
/// Evaluates `shouldIntercept` lock-free and never blocks on MainActor or disk I/O inside the tap callback.
final class MediaKeyTap: @unchecked Sendable {
    private let interceptLock = OSAllocatedUnfairLock(initialState: false)
    private let stateLock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onAction: @MainActor (MediaKeyAction) -> Void

    init(onAction: @escaping @MainActor (MediaKeyAction) -> Void) {
        self.onAction = onAction
    }

    deinit {
        stop()
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPrompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    var shouldIntercept: Bool {
        get { interceptLock.withLock { $0 } }
        set { interceptLock.withLock { $0 = newValue } }
    }

    var isRunning: Bool {
        stateLock.withLock { tapPort != nil }
    }

    /// Attempts to start the active session event tap. Returns true if active interception is running.
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        if tapPort != nil {
            stateLock.unlock()
            return true
        }
        stateLock.unlock()

        guard Self.isAccessibilityTrusted else { return false }

        let ready = DispatchSemaphore(value: 0)
        var created = false

        let worker = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let mask = CGEventMask(1 << MediaKeyParser.systemDefinedTypeRawValue)
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.tapCallback,
                userInfo: userInfo
            ) else {
                ready.signal()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()

            self.stateLock.withLock {
                self.tapPort = port
                self.runLoopSource = source
                self.runLoop = loop
            }

            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            created = true
            ready.signal()

            CFRunLoopRun()

            self.stateLock.withLock {
                if let src = self.runLoopSource {
                    CFRunLoopRemoveSource(loop, src, .commonModes)
                }
                if let p = self.tapPort {
                    CFMachPortInvalidate(p)
                }
                self.tapPort = nil
                self.runLoopSource = nil
                self.runLoop = nil
            }
        }
        worker.name = "com.hazelkahlil.DisplayVolume.MediaKeyTap"
        worker.qualityOfService = .userInteractive
        stateLock.withLock { self.thread = worker }
        worker.start()
        ready.wait()

        if !created {
            stateLock.withLock { self.thread = nil }
        }
        return created
    }

    func stop() {
        let loop: CFRunLoop? = stateLock.withLock {
            let current = runLoop
            runLoop = nil
            return current
        }
        if let loop {
            CFRunLoopStop(loop)
        }
        stateLock.withLock {
            thread = nil
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let port = stateLock.withLock { tapPort }
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == MediaKeyParser.systemDefinedTypeRawValue,
              interceptLock.withLock({ $0 }),
              let nsEvent = NSEvent(cgEvent: event),
              let parsed = MediaKeyParser.parse(
                  subtype: nsEvent.subtype.rawValue,
                  data1: nsEvent.data1,
                  modifierFlags: nsEvent.modifierFlags
              ) else {
            return Unmanaged.passUnretained(event)
        }

        if parsed.isKeyDown {
            // Avoid rapid mute toggling when holding down F10/Mute.
            if parsed.action != .toggleMute || !parsed.isRepeat {
                let action = parsed.action
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.onAction(action)
                    }
                }
            }
        }

        // Swallow both keyDown and keyUp so macOS never displays the locked-speaker OSD bezel.
        return nil
    }

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handleEvent(proxy: proxy, type: type, event: event)
    }
}
