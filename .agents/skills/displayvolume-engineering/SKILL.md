---
name: displayvolume-engineering
description: Engineering, debugging, performance auditing, and release workflow for DisplayVolume (macOS external display volume + full input/output audio controller). Use whenever modifying DisplayVolume code, fixing UI/OSD/CoreAudio bugs, optimizing latency or CPU usage, or cutting a release.
---

# DisplayVolume Engineering Skill

Use this skill for all development, bug-fixing, performance optimization, and release tasks in `DisplayVolume`.

## 1. Architecture Map

| Layer | Files | Responsibility |
| :--- | :--- | :--- |
| **Shared CoreAudio HAL & Math** | `Sources/Shared/AudioDevice.swift`, `Sources/Shared/VolumeModel.swift`, `Sources/Shared/Localization.swift` | Single-pass `AudioDeviceCatalog.captureSnapshot()`, HAL scalar/mute control, `MicrophoneControl` (hardware + soft-mute), `VolumeIPC`, pure testable math (`VolumeMath`, `InputMuteMath`, `DispatchThrottleMath`) |
| **Background Engine (`LaunchAgent`)** | `Sources/Engine/VolumeEngine.swift`, `AudioRoute.swift`, `AudioGain.c`, `MediaKeyTap.swift`, `Hotkeys.swift`, `VolumeOSD.swift` | CoreAudio Process Tap + lock-free C17 DSP ramp/SIMD, `F10–F12` CGEventTap fallback, global `⌃⌥⇧ M` mic mute hotkey, top-right Liquid Glass OSD |
| **Menu Bar UI App** | `Sources/App/DisplayVolumeApp.swift`, `PopoverView.swift`, `VolumeComponents.swift`, `MenuBarIconRenderer.swift` | `VolumeController` (`@Published` diff-guarded), native `NSPopover`, `SmoothNativeSlider`, `EngineProvisioner`, CLI diagnostics (`--diagnose`, `--engine-status`, `--self-test`, `--bench`) |
| **Build & Quality Gates** | `Scripts/build.sh`, `Scripts/verify.sh`, `Scripts/package_dmg.sh`, `Tests/RunTests.swift`, `.github/workflows/ci.yml` | Cached icon generation + parallel `swiftc`, static anti-pattern guards, unit tests, latency budgets, DMG packaging |

## 2. First-Principles Design & Debug Checklist

Before editing code, check which invariant applies:

1. **Idle CPU or phantom SwiftUI redraws?**
   - Inspect `sample <PID> 2 1` and `ps -axo pid,pcpu,cputime,etime,comm`.
   - NEVER pass `@Published` properties as `inout` (Swift copy-in/copy-out triggers `objectWillChange` even when unchanged); always compare directly (`if prop != next { prop = next }`).
   - Run `--self-test` to verify Combine emits 0 `objectWillChange` events on identical snapshots.
2. **Popover open lag or drag stutter?**
   - Run `./build/DisplayVolume.app/Contents/MacOS/DisplayVolume --bench`.
   - Popover open must execute at most **1** `AudioDeviceCatalog.captureSnapshot()` scan (never duplicate in `PopoverView.onAppear`).
   - Slider drags must throttle HAL/XPC (`>= 20–25 ms`) via `DispatchThrottleMath.shouldEmit` and NEVER write `UserDefaults` plists while `isDragging == true`.
   - All mutating commands (output volume, limits, mic gain/mute, preferences, media-key leases) must flow through authenticated Mach XPC (`setConnectionCodeSigningRequirement`), never `DistributedNotificationCenter`.
   - `VolumeEngine.publishState` must use `cachedAccessibilityTrusted`, never live `AXIsProcessTrusted()`.
3. **Slider jumping or dropped clicks?**
   - Verify `SmoothNativeSlider.updateNSView` freezes range while `isTracking`, invalidates gestures when `sessionKey` changes, and calls `context.coordinator.syncExternalValue(rounded)` when `!isTracking`.
   - Verify optimistic settling locks (`250–300 ms`) schedule trailing reconciliation readback and only preempt on strictly newer `lastTriggerNonce`.
4. **Audio drops / spurious reconnects / MainActor stalls?**
   - `AudioRoute.start/stop` must run on `routeQueue` (never block MainActor inside `AudioDeviceStart`), with `mData == NULL` disabled HAL streams separated from `layoutError` in `AudioGain.c`, and watchdog consuming both `layoutChanged` and `renderedCallbackCount`.
5. **OTA release packaging & signing (`Scripts/build_ota.sh`)**:
   - Never commit Ed25519 private keys to the repository (read exclusively from macOS Keychain service `com.hazelkahlil.DisplayVolume.ota-signing-key`).
   - Run `./Scripts/build_ota.sh "<release notes>"` to produce same-source `DisplayVolume-vX.Y.Z.dmg`, `DisplayVolume-vX.Y.Z-arm64.zip`, Ed25519-signed & self-verified `ota-manifest.json`, and `SHA256SUMS.txt`.
5. **OSD dark shadow box or UI alignment glitches?**
   - Verify `VolumeOSD.swift` keeps `shadowInset >= 24`, `container.wantsLayer = false`, `p.hasShadow = false`, and `p.backgroundColor = .clear`.
6. **Microphone control triggers orange privacy dot or degrades AirPods sound?**
   - Never open a CoreAudio capture stream (`AVAudioEngine`, `AudioQueueNewInput`, `AVCaptureSession`) for mic control. Use HAL properties (`kAudioDevicePropertyVolumeScalar`, `kAudioDevicePropertyMute`) exclusively.

## 3. Standard Development & Release Flow

1. **Create a feature/fix branch** (never push unverified work directly to `main`):
   ```bash
   git checkout -b fix/<short-name>
   ```
2. **Run full verification gate** (static guards + parallel build + unit tests + codesign + latency budget):
   ```bash
   ./Scripts/verify.sh
   ```
3. **Install locally & verify live hardware** (when changing UI, OSD, hotkeys, or audio routing):
   ```bash
   ./Scripts/verify.sh --install "$HOME/Applications"
   open -n "$HOME/Applications/DisplayVolume.app"
   "$HOME/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume" --diagnose
   "$HOME/Applications/DisplayVolume.app/Contents/MacOS/DisplayVolume" --engine-status
   ```
   Confirm:
   - `phase: "active"` remains stable across 5+ seconds of silence.
   - `mediaKeysAuthorized: true` and `mediaKeysActive: true`.
   - Built-in mic mute/gain, Continuity auto-gain detection, and native speaker switching all work and restore cleanly.
4. **Release bump** (if cutting a version):
   - Bump `CFBundleShortVersionString` and `CFBundleVersion` in BOTH `Info.plist` and `EngineInfo.plist`.
   - Run `./Scripts/verify.sh && ./Scripts/package_dmg.sh`.
   - Open a PR, wait for macOS GitHub Actions CI (`verify-macos`) to pass, merge to `main`, tag `vX.Y.Z`, and publish the DMG to GitHub Releases.
