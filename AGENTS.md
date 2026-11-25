# DisplayVolume — Project Engineering Rules (`AGENTS.md`)

These rules codify the first-principles invariants learned from building and debugging `DisplayVolume` (see [`docs/RETROSPECTIVE-2026-11.md`](docs/RETROSPECTIVE-2026-11.md)). Every contributor and AI agent working in this repository MUST follow them.

## 1. Architecture & Process Boundaries

- **Two-process split is mandatory**:
  - `DisplayVolume.app` (Menu bar UI + popover + native HAL output/input controls + primary `MediaKeyTap`).
  - `DisplayVolumeEngine.app` (LaunchAgent background CoreAudio Process Tap + `AudioGain.c` real-time DSP + `VolumeOSD` + global `⌃⌥⇧ M` mic mute hotkey + fallback `MediaKeyTap`).
  - Quitting the UI icon must NEVER stop audio attenuation or spike external speaker volume back to 100%.
- **Version lockstep**: `Info.plist` and `EngineInfo.plist` MUST keep identical `CFBundleShortVersionString` and `CFBundleVersion` values so `EngineProvisioner` upgrades cleanly.

## 2. State Ownership & Anti-Stutter Invariants

1. **Diff-before-publish (`@Published` & Status Bar)**:
   - NEVER assign a `@Published` property in `VolumeController` unconditionally inside timers, IPC handlers, or CoreAudio callbacks. Always use `assignIfChanged(&prop, value)` so unchanged ticks emit zero phantom `objectWillChange` events and never wake up the hidden SwiftUI `NSPopover`.
   - Guard `NSStatusBarButton` redraws with `StatusItemRenderKey` so `MenuBarIconRenderer.makeIcon` never re-rasterizes identical icons.
2. **Slider echo & external-update sync**:
   - Every slider (`SmoothNativeSlider`) must sync `Coordinator.lastSentValue` on external `updateNSView` updates (when `!isTracking`) so clicking back to a previously visited value after an `F10–F12` key press or preset click is never dropped.
   - Use optimistic settling locks (`250–300 ms`) during UI drag while allowing hardware triggers (`.mediaKey`, `.hotkey`, `.scroll`) to override immediately.
3. **Engine watchdog silence rule**:
   - CoreAudio legitimately pauses IOProc callbacks when no app is playing audio (`!device.isRunningSomewhere`). The watchdog MUST check `device.isAlive` and reset `lastCallbackTime` while `!device.isRunningSomewhere` — never reconnect-loop during idle silence.
   - Distinguish `phase == .idle && isEnabled` ("Reconnecting…") from `!isEnabled` ("Paused") in the UI.

## 3. Main-Thread IPC & Real-Time Audio Budgets

- **Single-pass HAL enumeration**: Always use `AudioDeviceCatalog.captureSnapshot()` to read outputs, inputs, and defaults in one scan. Never scan `allDevices()` multiple times on popover open, and debounce `kAudioHardwarePropertyDevices` bursts (`>= 60 ms`).
- **Switch by cached `AudioDeviceID`**: Call `setDefaultOutput(deviceID:)` / `setDefaultInput(deviceID:)` directly when the ID is already in memory.
- **Throttle continuous drag hot paths**:
  - Software IPC drags: throttle to `>= 25 ms`, always flush on drag end.
  - Native HAL output & microphone drags: throttle to `>= 20 ms`, always flush on drag end.
  - NEVER write `UserDefaults` plists to disk or run trailing HAL readbacks per drag pixel — persist `savedPreMuteVolume` only on drag release or mute toggle.
- **No per-tick TCC IPC**: Cache `AXIsProcessTrusted()` in `VolumeEngine` and refresh on launch, topology changes, accessibility polling, or explicit user request — never inside `publishState()` during 40 Hz slider drags.
- **Non-blocking cold launch**: Run `EngineProvisioner.ensureInstalledAndRunning()` off the main thread so the status bar icon appears immediately.
- **Real-time C DSP (`Sources/Engine/AudioGain.c`)**:
  - Zero heap allocations, zero locks, zero Objective-C/Swift calls inside `render()`.
  - Avoid redundant full-buffer `memset` when overwriting all frames; hoist channel base pointers out of sample loops and preserve the SIMD-vectorizable steady-state (`remaining == 0`) fast path.

## 4. macOS Privacy, Hardware & Visual Invariants

- **Zero mic privacy dot & zero AirPods HFP downgrade**: Microphone volume, mute, and device switching MUST use CoreAudio HAL properties only (`kAudioDevicePropertyVolumeScalar`, `kAudioDevicePropertyMute`, `kAudioHardwarePropertyDefaultInputDevice`). Never open an audio input capture stream (`AVAudioEngine`, `AVCaptureSession`, `AudioQueueNewInput`).
- **Honest hardware capability reporting**: Always probe writable HAL properties at runtime. For auto-gain-only mics (e.g. Continuity iPhone microphone), display "Auto Gain" honestly instead of rendering a fake slider or fake mute button.
- **SDK safety**: Build with `-warnings-as-errors` (Swift) and `-Wall -Wextra -Werror` (C17). Never use deprecated macOS 13 constants like `kAudioDeviceTransportTypeContinuityCapture` (use `Wired` / `Wireless`).
- **Liquid Glass OSD (`VolumeOSD.swift`)**: Keep a transparent `shadowInset >= 24`, `container.wantsLayer = false`, and `panel.hasShadow = false` so macOS window bounds never clip soft glass shadows into rectangular dark artifacts.
- **Native monochrome alignment**: Default to macOS native controls, `NSPopover`, and neutral monochrome styling; keep primary controls directly visible without extra disclosure clicks.

## 5. Mandatory Verification Before Push / PR

Before committing, opening a PR, or releasing a new version, ALWAYS run:

```bash
./Scripts/verify.sh
```

This enforces version lockstep, all 8 static anti-pattern guards, parallel compilation (`-warnings-as-errors`), `RunTests` (including `AudioGain.c` `GainSelfTest`), `codesign --verify --deep --strict`, `DisplayVolume --self-test`, and `--bench` latency budgets. For changes touching UI, OSD, hotkeys, or CoreAudio routing, also verify on real hardware before merging.
