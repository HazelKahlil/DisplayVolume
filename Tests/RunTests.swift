import AppKit
import CoreAudio
import Foundation

private func check(_ condition: Bool, _ label: String) {
    if !condition {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
}

@main
struct DisplayVolumeTests {
    static func main() {
        // 1. C DSP GainSelfTest
        check(GainSelfTest(), "AudioGain.c DSP self-test (stereo, quad, ramp, mute, rejection)")

        // 2. VolumeMath clamping & step transitions
        check(VolumeMath.clampedVolume(95, limit: 80) == 80, "Clamp above limit")
        check(VolumeMath.clampedVolume(-10, limit: 80) == 0, "Clamp below zero")
        check(VolumeMath.applyStep(currentVolume: 60, limit: 80, muted: false, delta: 5) == (65, false), "Step up within limit")
        check(VolumeMath.applyStep(currentVolume: 78, limit: 80, muted: false, delta: 5) == (80, false), "Step up clamped at limit")
        check(VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: false, delta: -5) == (3, true), "Step down across zero mutes cleanly")
        check(VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: 5) == (40, false), "Step up from mute restores stored level")
        check(VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: -5) == (40, true), "Step down while muted keeps muted")

        // 3. InputMuteMath soft-gain mute fallback logic
        check(
            InputMuteMath.planSoftMute(currentPercent: 85, savedBeforeMute: nil, targetMuted: true)
                == .init(appliedPercent: 0, updatedSavedVolume: 85),
            "Soft mute stores pre-mute gain and drops applied level to 0"
        )
        check(
            InputMuteMath.planSoftMute(currentPercent: 0, savedBeforeMute: 85, targetMuted: false)
                == .init(appliedPercent: 85, updatedSavedVolume: 85),
            "Soft unmute restores saved pre-mute gain"
        )
        check(
            InputMuteMath.planSoftMute(currentPercent: 0, savedBeforeMute: nil, targetMuted: false)
                == .init(appliedPercent: 50, updatedSavedVolume: 50),
            "Soft unmute without prior saved value recovers cleanly to 50%"
        )
        check(
            InputMuteMath.planSoftMute(currentPercent: 40, savedBeforeMute: 85, targetMuted: false)
                == .init(appliedPercent: 40, updatedSavedVolume: 40),
            "Unmuting when already audible keeps current level"
        )

        // 4. MediaKeyParser NX_SYSDEFINED decoding
        let subtype = MediaKeyParser.auxControlSubtype
        let soundUpDown = (MediaKeyParser.soundUpKey << 16) | (0x0A << 8)
        let soundUpUp = (MediaKeyParser.soundUpKey << 16) | (0x0B << 8)
        let soundDownRepeat = (MediaKeyParser.soundDownKey << 16) | (0x0A << 8) | 0x01
        let muteDown = (MediaKeyParser.muteKey << 16) | (0x0A << 8)
        let brightnessDown = (2 << 16) | (0x0A << 8)

        check(
            MediaKeyParser.parse(subtype: subtype, data1: soundUpDown, modifierFlags: [])
                == .init(action: .volumeUp(fine: false), isKeyDown: true, isRepeat: false),
            "Parse volume up keyDown"
        )
        check(
            MediaKeyParser.parse(subtype: subtype, data1: soundUpUp, modifierFlags: [])
                == .init(action: .volumeUp(fine: false), isKeyDown: false, isRepeat: false),
            "Parse volume up keyUp"
        )
        check(
            MediaKeyParser.parse(subtype: subtype, data1: soundDownRepeat, modifierFlags: [.shift, .option])
                == .init(action: .volumeDown(fine: true), isKeyDown: true, isRepeat: true),
            "Parse Shift+Option fine volume down repeat"
        )
        check(
            MediaKeyParser.parse(subtype: subtype, data1: muteDown, modifierFlags: [])
                == .init(action: .toggleMute, isKeyDown: true, isRepeat: false),
            "Parse mute keyDown"
        )
        check(
            MediaKeyParser.parse(subtype: subtype, data1: soundUpDown, modifierFlags: [.option]) == nil,
            "Pass Option+Volume straight through for macOS Sound Settings"
        )
        check(
            MediaKeyParser.parse(subtype: subtype, data1: soundUpDown, modifierFlags: [.command]) == nil,
            "Pass Command+Volume straight through"
        )
        check(
            MediaKeyParser.parse(subtype: subtype, data1: brightnessDown, modifierFlags: []) == nil,
            "Ignore non-volume media keys (brightness)"
        )
        check(
            MediaKeyParser.parse(subtype: 99, data1: soundUpDown, modifierFlags: []) == nil,
            "Ignore unrelated NX_SYSDEFINED subtypes"
        )

        // 5. Device classification rules (Outputs + Inputs)
        let dpMonitor = AudioDeviceInfo(
            id: 1, name: "Redmi 27 NU", uid: "dp-1", transport: kAudioDeviceTransportTypeDisplayPort,
            outputChannels: 2, volumeControlAvailable: false, isHidden: false
        )
        let hdmiTV = AudioDeviceInfo(
            id: 2, name: "LG OLED", uid: "hdmi-1", transport: kAudioDeviceTransportTypeHDMI,
            outputChannels: 2, volumeControlAvailable: false, isHidden: false
        )
        let speakers = AudioDeviceInfo(
            id: 3, name: "MacBook Pro Speakers", uid: "builtin-out", transport: kAudioDeviceTransportTypeBuiltIn,
            outputChannels: 2, volumeControlAvailable: true, muteControlAvailable: true, isHidden: false
        )
        let builtInMic = AudioDeviceInfo(
            id: 4, name: "MacBook Pro Microphone", uid: "builtin-in", transport: kAudioDeviceTransportTypeBuiltIn,
            outputChannels: 0, inputChannels: 1, volumeControlAvailable: false,
            inputVolumeControlAvailable: true, inputMuteControlAvailable: true, isHidden: false
        )
        let usbMicNoHwMute = AudioDeviceInfo(
            id: 5, name: "Wireless Mic Rx", uid: "usb-mic", transport: kAudioDeviceTransportTypeUSB,
            outputChannels: 0, inputChannels: 2, volumeControlAvailable: false,
            inputVolumeControlAvailable: true, inputMuteControlAvailable: false, isHidden: false
        )
        let continuityMic = AudioDeviceInfo(
            id: 6, name: "iPhone Mic", uid: "cc-mic", transport: kAudioDeviceTransportTypeContinuityCaptureWired,
            outputChannels: 0, inputChannels: 1, volumeControlAvailable: false,
            inputVolumeControlAvailable: false, inputMuteControlAvailable: false, isHidden: false
        )
        let virtualDriver = AudioDeviceInfo(
            id: 7, name: "TRTC Audio Device", uid: "virt-1", transport: kAudioDeviceTransportTypeVirtual,
            outputChannels: 2, inputChannels: 2, volumeControlAvailable: true,
            inputVolumeControlAvailable: true, inputMuteControlAvailable: true, isHidden: false
        )

        check(dpMonitor.isAutoControllable, "DisplayPort locked monitor is auto-controllable")
        check(hdmiTV.isAutoControllable, "HDMI locked monitor is auto-controllable")
        check(!speakers.isAutoControllable && speakers.isPhysicalOutput, "Built-in speakers use native hardware control")
        check(builtInMic.isPhysicalInput && builtInMic.inputMuteSupported, "Built-in mic is physical input with mute")
        check(usbMicNoHwMute.isPhysicalInput && usbMicNoHwMute.inputMuteSupported, "USB mic supports soft-mute fallback via scalar gain")
        check(continuityMic.transportKind == .continuity && continuityMic.isPhysicalInput && !continuityMic.inputMuteSupported, "Continuity iPhone mic recognized as auto-gain-only")
        check(continuityMic.symbolName(forInput: true) == "iphone", "Continuity mic uses iphone SF Symbol")
        check(!virtualDriver.isAutoControllable && !virtualDriver.isPhysicalOutput && !virtualDriver.isPhysicalInput, "Virtual drivers are never classified as physical devices")

        // 6. VolumeState Codable & shownVolume semantics
        let sampleState = VolumeState(
            enginePID: 1234, phase: .active, deviceUID: "dp-1", deviceName: "Redmi 27 NU",
            transportLabel: "DisplayPort", isLockedOutput: true, isControllable: true,
            volume: 85, volumeLimit: 70, muted: false, enabled: true, verifiedCapture: true,
            mediaKeysAuthorized: true, mediaKeysActive: true, shortcutsAvailable: true,
            showOSD: true, showMenuBarPercent: false, scrollOnIconEnabled: true,
            lastTriggerSource: .mediaKey, lastTriggerNonce: 7, message: nil
        )
        check(sampleState.shownVolume == 70, "shownVolume respects volumeLimit ceiling")
        check(sampleState.atCeiling, "atCeiling detects volume >= volumeLimit")
        let encoded = try! JSONEncoder().encode(sampleState)
        let decoded = try! JSONDecoder().decode(VolumeState.self, from: encoded)
        check(decoded == sampleState, "VolumeState JSON round-trip")

        print("ALL DISPLAYVOLUME UNIT TESTS PASSED")
    }
}
