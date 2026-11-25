import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import os

enum MediaKeyAction: Equatable, Sendable {
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

    struct ParsedEvent: Equatable, Sendable {
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

/// Thread-isolated, Swift-6-safe CGEventTap for hardware Magic Keyboard / MacBook F10–F12 volume keys.
/// Uses generation tokens to discard stale events after stop/restart and avoids stop-before-CFRunLoopRun races.
final class MediaKeyTap: @unchecked Sendable {
    private struct InterceptState {
        var shouldIntercept: Bool = false
        var generation: UInt64 = 0
    }

    private struct LifecycleState {
        var generation: UInt64 = 0
        var runLoop: CFRunLoop?
        var tapPort: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var stopRequested: Bool = false
        var isStarting: Bool = false
    }

    private let interceptState = OSAllocatedUnfairLock(initialState: InterceptState())
    private let lifecycle = OSAllocatedUnfairLock(initialState: LifecycleState())
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
        get { interceptState.withLock { $0.shouldIntercept } }
        set { interceptState.withLock { $0.shouldIntercept = newValue } }
    }

    var isRunning: Bool {
        lifecycle.withLock { state in
            guard let port = state.tapPort, !state.stopRequested else { return false }
            return CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
        }
    }

    /// Starts the active session event tap on a dedicated high-priority thread with bounded wait.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        guard Self.isAccessibilityTrusted else { return false }

        let targetGen: UInt64? = lifecycle.withLock { state in
            if state.isStarting { return nil }
            if let port = state.tapPort, CFMachPortIsValid(port), !state.stopRequested {
                return nil
            }
            state.generation &+= 1
            state.stopRequested = false
            state.isStarting = true
            return state.generation
        }

        guard let gen = targetGen else {
            return isRunning
        }

        interceptState.withLock { $0.generation = gen }
        let ready = DispatchSemaphore(value: 0)
        let startedFlag = OSAllocatedUnfairLock(initialState: false)

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
                self.lifecycle.withLock { state in
                    if state.generation == gen {
                        state.isStarting = false
                    }
                }
                ready.signal()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            let shouldAbortImmediately: Bool = self.lifecycle.withLock { state in
                guard state.generation == gen && !state.stopRequested else { return true }
                state.tapPort = port
                state.runLoopSource = source
                state.runLoop = loop
                state.isStarting = false
                return false
            }

            if shouldAbortImmediately {
                CFMachPortInvalidate(port)
                ready.signal()
                return
            }

            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            startedFlag.withLock { $0 = true }
            ready.signal()

            // Guard against stop() arriving right after ready.signal() before CFRunLoopRun() enters.
            while true {
                let cancelled = self.lifecycle.withLock { $0.generation != gen || $0.stopRequested }
                if cancelled { break }
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }

            // Always clean up local port/source deterministically inside worker thread.
            if let source {
                CFRunLoopRemoveSource(loop, source, .commonModes)
            }
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)

            self.lifecycle.withLock { state in
                if state.generation == gen {
                    state.tapPort = nil
                    state.runLoopSource = nil
                    state.runLoop = nil
                    state.isStarting = false
                }
            }
        }
        worker.name = "com.hazelkahlil.DisplayVolume.MediaKeyTap.\(gen)"
        worker.qualityOfService = .userInteractive
        worker.start()

        // Bounded 1.0s startup wait so main thread never deadlocks under heavy system load.
        let waitResult = ready.wait(timeout: .now() + 1.0)
        if waitResult == .timedOut {
            return isRunning
        }
        return startedFlag.withLock { $0 }
    }

    func stop() {
        let loopToStop: CFRunLoop? = lifecycle.withLock { state in
            state.stopRequested = true
            state.generation &+= 1
            let current = state.runLoop
            state.runLoop = nil
            return current
        }
        interceptState.withLock { state in
            state.shouldIntercept = false
            state.generation &+= 1
        }
        if let loopToStop {
            CFRunLoopStop(loopToStop)
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let port = lifecycle.withLock { state -> CFMachPort? in
                guard !state.stopRequested else { return nil }
                return state.tapPort
            }
            if let port, CFMachPortIsValid(port) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let (active, gen) = interceptState.withLock { ($0.shouldIntercept, $0.generation) }
        guard type.rawValue == MediaKeyParser.systemDefinedTypeRawValue,
              active,
              let nsEvent = NSEvent(cgEvent: event),
              let parsed = MediaKeyParser.parse(
                  subtype: nsEvent.subtype.rawValue,
                  data1: nsEvent.data1,
                  modifierFlags: nsEvent.modifierFlags
              ) else {
            return Unmanaged.passUnretained(event)
        }

        if parsed.isKeyDown {
            if parsed.action != .toggleMute || !parsed.isRepeat {
                let action = parsed.action
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let current = self.interceptState.withLock { ($0.shouldIntercept, $0.generation) }
                    guard current.0 && current.1 == gen else { return }
                    MainActor.assumeIsolated {
                        self.onAction(action)
                    }
                }
            }
        }

        return nil
    }

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handleEvent(proxy: proxy, type: type, event: event)
    }
}
