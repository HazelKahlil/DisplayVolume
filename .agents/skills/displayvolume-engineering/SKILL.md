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
   - Every `@Published` write in `VolumeController` must go through `assignIfChanged(...)`.
   - Heartbeat timers must check `stateFile` modification time before decoding JSON and avoid calling `AXIsProcessTrusted()` when already trusted.
2. **Popover open lag or drag stutter?**
   - Run `./build/DisplayVolume.app/Contents/MacOS/DisplayVolume --bench`.
   - Popover open must execute at most **1** `AudioDeviceCatalog.captureSnapshot()` scan (never duplicate in `PopoverView.onAppear`).
   - Slider drags must throttle HAL/IPC (`>= 20–25 ms`) via `DispatchThrottleMath.shouldEmit` and NEVER write `UserDefaults` plists while `isDragging == true`.
   - `VolumeEngine.publishState` must use `cachedAccessibilityTrusted`, never live `AXIsProcessTrusted()`.
3. **Slider jumping or dropped clicks?**
   - Verify `SmoothNativeSlider.updateNSView` calls `context.coordinator.syncExternalValue(rounded)` when `!isTracking`.
   - Verify optimistic settling locks (`250–300 ms`) cover IPC round-trip without blocking `.mediaKey`/`.hotkey`/`.scroll` triggers.
4. **Audio drops / spurious reconnects during silence?**
   - Check `VolumeEngine.onWatchdogTick`: silence pauses CoreAudio callbacks (`!route.device.isRunningSomewhere`); only trigger reconnect when `isAlive && isRunningSomewhere && stalled > 3.5s`.
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
