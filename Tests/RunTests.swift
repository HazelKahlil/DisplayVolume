import AppKit
import CoreAudio
import CryptoKit
import Foundation

private func check(_ condition: Bool, _ label: String) {
    if !condition {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
}

private func checkThrows<T>(_ expected: OTAValidationError, _ label: String, _ block: () throws -> T) {
    do {
        _ = try block()
        fputs("FAIL (expected error \(expected)): \(label)\n", stderr)
        exit(1)
    } catch let err as OTAValidationError {
        if err != expected {
            fputs("FAIL (got \(err), expected \(expected)): \(label)\n", stderr)
            exit(1)
        }
    } catch {
        fputs("FAIL (unexpected error \(error)): \(label)\n", stderr)
        exit(1)
    }
}

@main
struct DisplayVolumeTests {
    static func main() {
        // 1. C DSP GainSelfTest (stereo, quad, disabled mData == NULL, SIMD steady-state, tail zeroing, layout rejection)
        check(GainSelfTest(), "AudioGain.c DSP self-test")

        // 2. VolumeMath clamping, stepping & overflow protection
        check(VolumeMath.clampedVolume(95, limit: 80) == 80, "Clamp above limit")
        check(VolumeMath.clampedVolume(-10, limit: 80) == 0, "Clamp below zero")
        check(VolumeMath.applyStep(currentVolume: 60, limit: 80, muted: false, delta: 5) == (65, false), "Step up within limit")
        check(VolumeMath.applyStep(currentVolume: 78, limit: 80, muted: false, delta: 5) == (80, false), "Step up clamped at limit")
        check(VolumeMath.applyStep(currentVolume: 3, limit: 100, muted: false, delta: -5) == (3, true), "Step down across zero mutes cleanly")
        check(VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: 5) == (40, false), "Step up from mute restores stored level")
        check(VolumeMath.applyStep(currentVolume: 40, limit: 100, muted: true, delta: -5) == (40, true), "Step down while muted keeps muted")
        check(VolumeMath.applyStep(currentVolume: 50, limit: 80, muted: false, delta: Int.max) == (80, false), "Positive Int.max delta never overflows")
        check(VolumeMath.applyStep(currentVolume: 50, limit: 80, muted: false, delta: Int.min) == (50, true), "Negative Int.min delta never overflows")

        // 3. Multi-channel mute aggregation (no false-muted on partial channel failure)
        check(ChannelControlMap.aggregateMuteRead([true, true], expectedCount: 2) == true, "All channels muted -> true")
        check(ChannelControlMap.aggregateMuteRead([true, false], expectedCount: 2) == false, "Partial mute [true, false] -> false (never lie)")
        check(ChannelControlMap.aggregateMuteRead([true, nil], expectedCount: 2) == nil, "Unreadable second channel -> nil (unknown)")
        check(ChannelControlMap.aggregateMuteRead([], expectedCount: 0) == nil, "Empty channels -> nil")

        // 4. InputMuteMath soft-gain mute fallback logic
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

        // 5. MediaKeyParser NX_SYSDEFINED decoding
        let subtype = MediaKeyParser.auxControlSubtype
        let soundUpDown = (MediaKeyParser.soundUpKey << 16) | (0x0A << 8)
        let soundUpUp = (MediaKeyParser.soundUpKey << 16) | (0x0B << 8)
        let soundDownRepeat = (MediaKeyParser.soundDownKey << 16) | (0x0A << 8) | 0x01
        let muteDown = (MediaKeyParser.muteKey << 16) | (0x0A << 8)
        let brightnessDown = (2 << 16) | (0x0A << 8)

        check(MediaKeyParser.parse(subtype: subtype, data1: soundUpDown, modifierFlags: []) == .init(action: .volumeUp(fine: false), isKeyDown: true, isRepeat: false), "Parse volume up keyDown")
        check(MediaKeyParser.parse(subtype: subtype, data1: soundUpUp, modifierFlags: []) == .init(action: .volumeUp(fine: false), isKeyDown: false, isRepeat: false), "Parse volume up keyUp")
        check(MediaKeyParser.parse(subtype: subtype, data1: soundDownRepeat, modifierFlags: [.shift, .option]) == .init(action: .volumeDown(fine: true), isKeyDown: true, isRepeat: true), "Parse Shift+Option fine volume down repeat")
        check(MediaKeyParser.parse(subtype: subtype, data1: muteDown, modifierFlags: []) == .init(action: .toggleMute, isKeyDown: true, isRepeat: false), "Parse mute keyDown")
        check(MediaKeyParser.parse(subtype: subtype, data1: soundUpDown, modifierFlags: [.option]) == nil, "Pass Option+Volume through")
        check(MediaKeyParser.parse(subtype: subtype, data1: soundUpDown, modifierFlags: [.command]) == nil, "Pass Command+Volume through")
        check(MediaKeyParser.parse(subtype: subtype, data1: brightnessDown, modifierFlags: []) == nil, "Ignore brightness media key")
        check(MediaKeyParser.parse(subtype: 99, data1: soundUpDown, modifierFlags: []) == nil, "Ignore unrelated subtype")

        // 6. Device classification rules
        let dpMonitor = AudioDeviceInfo(id: 1, name: "Redmi 27 NU", uid: "dp-1", transport: kAudioDeviceTransportTypeDisplayPort, outputChannels: 2, volumeControlAvailable: false, isHidden: false)
        let speakers = AudioDeviceInfo(id: 3, name: "MacBook Pro Speakers", uid: "builtin-out", transport: kAudioDeviceTransportTypeBuiltIn, outputChannels: 2, volumeControlAvailable: true, muteControlAvailable: true, isHidden: false)
        let builtInMic = AudioDeviceInfo(id: 4, name: "MacBook Pro Microphone", uid: "builtin-in", transport: kAudioDeviceTransportTypeBuiltIn, outputChannels: 0, inputChannels: 1, volumeControlAvailable: false, inputVolumeControlAvailable: true, inputMuteControlAvailable: true, isHidden: false)
        let continuityMic = AudioDeviceInfo(id: 6, name: "iPhone Mic", uid: "cc-mic", transport: kAudioDeviceTransportTypeContinuityCaptureWired, outputChannels: 0, inputChannels: 1, volumeControlAvailable: false, inputVolumeControlAvailable: false, inputMuteControlAvailable: false, isHidden: false)
        let virtualDriver = AudioDeviceInfo(id: 7, name: "TRTC Audio Device", uid: "virt-1", transport: kAudioDeviceTransportTypeVirtual, outputChannels: 2, inputChannels: 2, volumeControlAvailable: true, inputVolumeControlAvailable: true, inputMuteControlAvailable: true, isHidden: false)

        check(dpMonitor.isAutoControllable, "DisplayPort locked monitor is auto-controllable")
        check(!speakers.isAutoControllable && speakers.isPhysicalOutput, "Built-in speakers use native hardware control")
        check(builtInMic.isPhysicalInput && builtInMic.inputMuteSupported, "Built-in mic supports mute")
        check(continuityMic.transportKind == .continuity && continuityMic.isPhysicalInput && !continuityMic.inputMuteSupported, "Continuity iPhone mic recognized as auto-gain-only")
        check(!virtualDriver.isAutoControllable && !virtualDriver.isPhysicalOutput && !virtualDriver.isPhysicalInput, "Virtual drivers excluded from physical classification")

        // 7. VolumeState validation & Codable round-trip
        let sampleState = VolumeState(
            protocolVersion: VolumeState.currentProtocolVersion, engineBuild: 230, engineInstanceID: "inst-1",
            stateSequence: 4, routeGeneration: 2, enginePID: getpid(), phase: .active,
            deviceUID: "dp-1", deviceName: "Redmi 27 NU", transportLabel: "DisplayPort",
            isLockedOutput: true, isControllable: true, volume: 85, volumeLimit: 70,
            muted: false, enabled: true, verifiedCapture: true, mediaKeysAuthorized: true,
            mediaKeysActive: true, shortcutsAvailable: true, micHotkeyAvailable: true,
            showOSD: true, showMenuBarPercent: false, scrollOnIconEnabled: true,
            lastTriggerSource: .mediaKey, lastTriggerNonce: 7, message: nil
        )
        check(sampleState.shownVolume == 70 && sampleState.atCeiling, "shownVolume respects limit ceiling")
        let encoded = try! JSONEncoder().encode(sampleState)
        check(VolumeIPC.decodeValidatedState(encoded) == sampleState, "Validated state decode succeeds for live PID")

        var badProto = sampleState
        badProto.protocolVersion = 999
        check(VolumeIPC.decodeValidatedState(try! JSONEncoder().encode(badProto)) == nil, "Rejects wrong protocolVersion")

        var badVolume = sampleState
        badVolume.volume = 150
        check(VolumeIPC.decodeValidatedState(try! JSONEncoder().encode(badVolume)) == nil, "Rejects out-of-range volume")

        // 8. Drag throttle & single-pass HAL snapshot invariants
        check(!DispatchThrottleMath.shouldEmit(now: 1.010, lastSentAt: 1.000, minInterval: 0.020, isDragging: true), "Throttle during drag")
        check(DispatchThrottleMath.shouldEmit(now: 1.025, lastSentAt: 1.000, minInterval: 0.020, isDragging: true), "Emit after minInterval")
        check(DispatchThrottleMath.shouldEmit(now: 1.001, lastSentAt: 1.000, minInterval: 0.020, isDragging: false), "Flush on drag release")
        let snap = AudioDeviceCatalog.captureSnapshot()
        check(snap.querySucceeded, "Single-pass HAL snapshot succeeds")

        // 9. Ed25519 OTA manifest verification, anti-tamper, anti-downgrade, expiry, archive & preflight safety
        let testPriv = Curve25519.Signing.PrivateKey()
        let testKeys = ["test-k1": testPriv.publicKey.rawRepresentation.base64EncodedString()]
        let now = Date()
        let iso = ISO8601DateFormatter()
        let futureISO = iso.string(from: now.addingTimeInterval(86400 * 30))
        let pastISO = iso.string(from: now.addingTimeInterval(-60))

        func makeSigned(_ payload: OTAManifestPayload) -> SignedOTAManifest {
            let bytes = try! payload.canonicalData()
            let sig = try! testPriv.signature(for: bytes).base64EncodedString()
            return SignedOTAManifest(payload: payload, signature: sig)
        }

        let validPayload = OTAManifestPayload(
            schemaVersion: 1, keyID: "test-k1", channel: "stable",
            bundleID: VolumeIPC.suiteName, engineBundleID: VolumeIPC.engineBundleID,
            version: "2.3.0", build: 230, arch: "arm64", minMacOS: "14.4",
            archiveSize: 512_000, archiveSHA256: String(repeating: "a", count: 64),
            downloadURL: "https://github.com/HazelKahlil/DisplayVolume/releases/download/v2.3.0/DisplayVolume-v2.3.0-arm64.zip",
            publishedAt: iso.string(from: now), expiresAt: futureISO, releaseNotes: "Test release"
        )
        let validSigned = makeSigned(validPayload)
        let os15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let verified = try? OTAManifestVerifier.verify(validSigned, currentBuild: 220, currentOS: os15, currentArch: "arm64", now: now, trustedKeys: testKeys)
        check(verified == validPayload, "Valid Ed25519 OTA manifest passes verification")

        // Tampered payload with original signature must fail signature check
        let tamperedPayload = OTAManifestPayload(
            schemaVersion: 1, keyID: "test-k1", channel: "stable",
            bundleID: VolumeIPC.suiteName, engineBundleID: VolumeIPC.engineBundleID,
            version: "2.3.0", build: 230, arch: "arm64", minMacOS: "14.4",
            archiveSize: 512_000, archiveSHA256: String(repeating: "b", count: 64),
            downloadURL: validPayload.downloadURL, publishedAt: validPayload.publishedAt,
            expiresAt: futureISO, releaseNotes: "Tampered"
        )
        checkThrows(.invalidSignature, "Tampered SHA-256 fails Ed25519 check") {
            try OTAManifestVerifier.verify(SignedOTAManifest(payload: tamperedPayload, signature: validSigned.signature), currentBuild: 220, currentOS: os15, currentArch: "arm64", now: now, trustedKeys: testKeys)
        }

        // Downgrade / replay rejection
        checkThrows(.notNewer(currentBuild: 230, candidateBuild: 230), "Same build rejected (anti-replay)") {
            try OTAManifestVerifier.verify(validSigned, currentBuild: 230, currentOS: os15, currentArch: "arm64", now: now, trustedKeys: testKeys)
        }
        checkThrows(.notNewer(currentBuild: 240, candidateBuild: 230), "Older build rejected (anti-downgrade)") {
            try OTAManifestVerifier.verify(validSigned, currentBuild: 240, currentOS: os15, currentArch: "arm64", now: now, trustedKeys: testKeys)
        }

        // Expired manifest rejection
        let expiredPayload = OTAManifestPayload(
            schemaVersion: 1, keyID: "test-k1", channel: "stable",
            bundleID: VolumeIPC.suiteName, engineBundleID: VolumeIPC.engineBundleID,
            version: "2.3.0", build: 230, arch: "arm64", minMacOS: "14.4",
            archiveSize: 512_000, archiveSHA256: String(repeating: "a", count: 64),
            downloadURL: validPayload.downloadURL, publishedAt: validPayload.publishedAt,
            expiresAt: pastISO, releaseNotes: "Expired"
        )
        checkThrows(.expiredManifest(pastISO), "Expired OTA manifest rejected") {
            try OTAManifestVerifier.verify(makeSigned(expiredPayload), currentBuild: 220, currentOS: os15, currentArch: "arm64", now: now, trustedKeys: testKeys)
        }

        // Untrusted download host rejection
        let badHostPayload = OTAManifestPayload(
            schemaVersion: 1, keyID: "test-k1", channel: "stable",
            bundleID: VolumeIPC.suiteName, engineBundleID: VolumeIPC.engineBundleID,
            version: "2.3.0", build: 230, arch: "arm64", minMacOS: "14.4",
            archiveSize: 512_000, archiveSHA256: String(repeating: "a", count: 64),
            downloadURL: "https://evil.example.com/DisplayVolume.zip", publishedAt: validPayload.publishedAt,
            expiresAt: futureISO, releaseNotes: "Evil URL"
        )
        checkThrows(.untrustedDownloadURL("https://evil.example.com/DisplayVolume.zip"), "Untrusted download URL rejected") {
            try OTAManifestVerifier.verify(makeSigned(badHostPayload), currentBuild: 220, currentOS: os15, currentArch: "arm64", now: now, trustedKeys: testKeys)
        }

        // Zip-slip & path safety
        check((try? OTAArchiveSafety.validateEntryPaths(["DisplayVolume.app/Contents/Info.plist", "DisplayVolume.app/Contents/MacOS/DisplayVolume"])) != nil, "Valid zip entries accepted")
        checkThrows(.unsafeArchiveEntry("DisplayVolume.app/../../evil"), "Zip-slip '..' entry rejected") {
            try OTAArchiveSafety.validateEntryPaths(["DisplayVolume.app/../../evil", "DisplayVolume.app/Contents/MacOS/DisplayVolume"])
        }
        checkThrows(.unsafeArchiveEntry("/etc/passwd"), "Absolute zip entry rejected") {
            try OTAArchiveSafety.validateEntryPaths(["/etc/passwd", "DisplayVolume.app/Contents/MacOS/DisplayVolume"])
        }

        // Translocation / DMG mount preflight rejection
        do {
            try OTAInstallPreflight.validateInstallTarget(bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/DisplayVolume.app"))
            check(false, "AppTranslocation path must be rejected")
        } catch is OTAValidationError {
        } catch {
            check(false, "Unexpected error on AppTranslocation: \(error)")
        }
        do {
            try OTAInstallPreflight.validateInstallTarget(bundleURL: URL(fileURLWithPath: "/Volumes/DisplayVolume v2.3.0/DisplayVolume.app"))
            check(false, "Mounted /Volumes DMG path must be rejected")
        } catch is OTAValidationError {
        } catch {
            check(false, "Unexpected error on /Volumes: \(error)")
        }

        print("ALL DISPLAYVOLUME UNIT TESTS PASSED")
    }
}
