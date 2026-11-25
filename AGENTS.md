# DisplayVolume — Project Engineering Rules (`AGENTS.md`)

These rules codify the first-principles invariants learned from building, profiling, and peer-reviewing `DisplayVolume` (see [`docs/RETROSPECTIVE-2026-11.md`](docs/RETROSPECTIVE-2026-11.md)). Every contributor and AI agent working in this repository MUST follow them.

## 1. Architecture, Authenticated XPC & Process Boundaries

- **Two-process split is mandatory**:
  - `DisplayVolume.app` (Menu bar UI + popover + native HAL output controls + primary `MediaKeyTap` + Ed25519 OTA updater).
  - `DisplayVolumeEngine.app` (LaunchAgent background CoreAudio Process Tap + `AudioGain.c` real-time DSP + `VolumeOSD` + global `⌃⌥⇧ M` mic mute hotkey + serialized single-writer microphone controller + fallback `MediaKeyTap`).
  - Quitting the UI icon must NEVER stop audio attenuation or spike external speaker volume back to 100%.
- **Authenticated Mach XPC only**: All mutating Engine commands run over `NSXPCListener` (`com.hazelkahlil.DisplayVolume.Engine.xpc`) protected by `setConnectionCodeSigningRequirement` (matching Team ID + bundle ID) and `effectiveUserIdentifier == getuid()`. Never accept commands over unauthenticated `DistributedNotificationCenter`.
- **Single-writer microphone control**: Route microphone gain/mute mutations through `VolumeEngine` XPC so UI slider drags and global `⌃⌥⇧ M` hotkeys never race on HAL properties or `UserDefaults`.
- **Version lockstep & transactional install**: `Info.plist` and `EngineInfo.plist` MUST match (`CFBundleShortVersionString` & `CFBundleVersion`). Engine installs/updates run under cross-process `InstallTransactionLock` (`flock`), verify full nested bundle signatures + Team ID, enforce monotonic upgrades, and preserve previous backup for automatic rollback.

## 2. State Ownership & Anti-Stutter Invariants

1. **Direct compare-before-write for `@Published` (NEVER pass `@Published` as `inout`)**:
   - In Swift, passing an `@Published` property as `inout` writes back on return even when unchanged, firing phantom `objectWillChange` events. ALWAYS write `if prop != next { prop = next }` directly at the assignment site, and keep the Combine zero-emission test passing in `--self-test`.
   - Split menu bar `StatusIconKey` (wave tier `0..3`, `muted`, `active`) from `StatusLabelKey` so percentage drags (`51% -> 52%`) and mic mute never re-rasterize `NSImage`.
2. **Slider session & external-update sync**:
   - Freeze slider `minValue`/`maxValue` during active tracking, sync `Coordinator.lastSentValue` on external updates, and invalidate active gestures when `sessionKey` (device UID) changes mid-drag.
   - Preempt optimistic state only on strictly newer `lastTriggerNonce`, and schedule a trailing reconciliation readback after drag release.
3. **CoreAudio route lifecycle & silence watchdog**:
   - Run `AudioRoute.start` / `stop` on `routeQueue` (never block `MainActor` inside `AudioDeviceStart`), with monotonic `routeGeneration` cancellation.
   - Distinguish HAL disabled streams (`mData == NULL`) from real `layoutError` in `AudioGain.c`, monitor all format/sample-rate selectors, and consume both `layoutChanged` and `renderedCallbackCount` in the watchdog while resetting idle timers when `!device.isRunningSomewhere`.
   - Track `systemSleeping` and `screensSleeping` separately so queued retries never fire while displays are asleep.

## 3. Main-Thread IPC & Real-Time Audio Budgets

- **Single-pass HAL enumeration**: Use `AudioDeviceCatalog.captureSnapshot()`, trim returned HAL arrays strictly to actual returned byte length, preserve previous device lists on transient HAL failure, and debounce `kAudioHardwarePropertyDevices` bursts (`>= 60 ms`).
- **Unified channel control maps**: Read, write, and observe HAL properties through the same `ChannelControlMap`. Report hardware mute `true` ONLY when EVERY mapped channel is muted, and require ALL writable channels to succeed on `writeMute`.
- **Throttle continuous drag hot paths**: Throttle IPC drags (`>= 25 ms`) and HAL drags (`>= 20 ms`), flush final value on release, and never persist `UserDefaults` plists while `isDragging == true`.
- **No per-tick TCC IPC**: Cache `AXIsProcessTrusted()` in `VolumeEngine`; never call it inside `publishState()`.
- **Real-time C DSP (`Sources/Engine/AudioGain.c`)**: Zero allocations, zero locks, zero ObjC/Swift calls inside `render()`. Preserve pointer hoisting, tail-only zeroing, and SIMD steady-state fast paths.

## 4. macOS Privacy, OTA Security & SDK Portability

- **Zero mic capture stream**: DisplayVolume itself never opens an audio capture stream for microphone controls (`AVAudioEngine`, `AVCaptureSession`, `AudioQueueNewInput` are forbidden in `AudioDevice.swift`).
- **Cryptographic OTA updates**: Every OTA manifest is Ed25519-signed over canonical JSON bytes (`OTAManifestVerifier`), checked for bundle ID, channel, architecture, `minMacOS`, expiry, monotonic `build > currentBuild`, HTTPS GitHub Release host, archive size + SHA-256, zip-slip/symlink tree audit, strict nested `codesign` + Team ID continuity, writable non-translocated target preflight, and non-playing swap guard.
- **SDK safety**: Build with `-warnings-as-errors` (Swift) and `-Wall -Wextra -Werror` (C17). Wrap macOS 26 Liquid Glass APIs (`.glassEffect`, `.buttonStyle(.glass)`) with `#if LIQUID_GLASS_SDK`.

## 5. Mandatory Verification Before Push / PR

```bash
./Scripts/verify.sh
```
