# DisplayVolume 10-Day Engineering Retrospective & First-Principles Root-Cause Analysis (2026-11-20 – 2026-11-25)

> Scope: `HazelKahlil/DisplayVolume` (full 10-day lifecycle from initial Codex prototype on 2026-11-20 through `v2.0.0`, `v2.1.0`, and the root-cause hardening release `v2.2.0` on 2026-11-25).

---

## 1. Change-Batch & Bottleneck Audit ("Slowest PRs / Iteration Batches")

During the first 5 days (`v1.0 → v2.1.0`), `DisplayVolume` shipped via **0 GitHub Pull Requests** (2 large direct commits to `main`, plus 6 distinct local iteration batches across Codex and Antigravity sessions). Treating each user-driven feature/fix batch as a virtual PR reveals where wall-clock time, build wait, and rework concentrated:

| Rank | Batch / Virtual PR | Date | Wall Time | Activity / Failures | Primary Bottleneck & Why It Was Slow |
| :---: | :--- | :--- | ---: | :--- | :--- |
| **1** | **Phase 0: `v1.0 → v1.4.1` Initial Architecture & Split** (Codex) | 2026-11-20 | **27.6 min** | 78 GUI/CUA actions | **Architecture rework**: started as single-process menu bar app; quitting UI caused 100% hardware volume blast, forcing mid-flight split into a persistent LaunchAgent daemon; built custom popup then discarded it for native `NSPopover`; upgraded app accidentally relaunched stale cached binary. |
| **2** | **Batch 1: `v2.0.0` Rewrite & Magic Keyboard `F10–F12` Tap** | 2026-11-23 | **19.6 min** | 233 steps · 6 builds · 14 CUA · **7 failures** | **Serial build tax + SDK/assertion misses**: 6 full serial builds (~2 min pure compile wait), 7 command/compile failures (non-existent `kAudioDeviceTransportTypeSPDIF`, SwiftUI `Binding` type mismatch, `VolumeMath` step-across-zero mute assertion). |
| **3** | **Batch 6: `v2.1.0` Unified Output + Microphone HAL Control** | 2026-11-24 | **17.4 min** | 108 steps · 3 builds · 8 CUA · 1 failure | **Live hardware state-machine surprises**: `VolumeEngine.swift` edited 7 times; macOS 13 deprecated `kAudioDeviceTransportTypeContinuityCapture` failed `-warnings-as-errors`; live testing caught idle-silence watchdog reconnect loops and misleading reconnect UI text. |
| **4** | **Batch 4: `v2.0.0` UX, Icon & OSD Shadow Artifact Fix** | 2026-11-23 | **7.7 min** | 80 steps · 1 build · 6 CUA | **Late visual/interaction rework**: 3rd icon redesign, slider jump/echo fixes, and fixing rectangular dark shadow clipping around the top-right Liquid Glass OSD. |
| **5** | **Batch 2+3: Native Controls Alignment & Drag Smoothing** | 2026-11-23 | **5.5 min** | 52 steps · 2 builds · 6 CUA | **Non-native UI rework**: removed nested disclosure drawers, replaced colored accents with native monochrome glass, replaced sticky SwiftUI `Slider` with `SmoothNativeSlider`. |

### Edit-Churn Hotspots (Repeated Modifications)

| File | Total Edits / Writes | Dominant Churn Driver |
| :--- | :---: | :--- |
| `Sources/Engine/VolumeEngine.swift` | **14** | Watchdog silence reconnect loop, Accessibility tap handoff, topology listeners, mic hotkey routing |
| `Sources/App/DisplayVolumeApp.swift` | **13** | Optimistic slider locking, HAL output/input listeners, status-bar rendering, LaunchAgent provisioning |
| `Sources/App/PopoverView.swift` | **13** | Flattening folded UI, monochrome native alignment, reconnect-state wording, mic/input sections |
| `Sources/Engine/VolumeOSD.swift` | **5** | Fixing layer-clipped rectangular shadow artifact; adding microphone mute HUD mode |
| `Sources/App/VolumeComponents.swift` | **5** | Replacing SwiftUI `Slider` with click-to-jump `ClickableNativeSlider` + tracking guard |
| `Sources/Shared/AudioDevice.swift` | **5** | SDK constant errors, adding HAL input/output volume & mute + Continuity detection |

---

## 2. Live Runtime Profiling & Stutter Audit (Before `v2.2.0`)

Live profiling of the running `v2.1.0` processes (`ps`, `sample` at 1 ms resolution, and Swift HAL micro-benchmarks on macOS) exposed **7 concrete runtime and build-time bottlenecks** that were still present even after `v2.1.0` shipped:

1. **Idle UI CPU Burn & Hidden SwiftUI Redraw Storm (`1m 50.92s` CPU over 12h 55m idle)**:
   - The menu bar UI process (`DisplayVolume`) burned **more CPU while completely idle than the 48 kHz real-time C DSP audio engine** (`1m 19.84s`).
   - `sample` captured `VolumeController.pollFallback()` firing every 5 seconds -> unconditionally assigning `@Published` properties (`optimisticVolume = nil`, `optimisticMuted = nil`, `optimisticLimit = nil`, `uiAccessibilityTrusted = trusted`) even when values were unchanged. Every assignment emitted `objectWillChange`, waking the hidden `NSHostingController<PopoverView>` to re-evaluate `PopoverView.body` and diff all views 24/7.
2. **4× Redundant Synchronous CoreAudio HAL Device Scans on Every Popover Open (`14.84 ms` avg / `21.67 ms` max)**:
   - Clicking the menu bar icon called `refreshAllAudioDevices()` (`allOutputDevices()` + `allInputDevices()` = 2 full scans), and `PopoverView.onAppear` immediately called `refreshAllAudioDevices()` a second time (= 4 full scans = ~100+ synchronous HAL XPC calls on the main thread right as the popover animation started).
   - Switching devices via `setDefaultOutput(uid:)` / `setDefaultInput(uid:)` re-scanned all devices again instead of using the cached `AudioDeviceID`.
3. **Unthrottled Main-Thread HAL + `UserDefaults` Disk Writes During Mic & Native Output Drags**:
   - While software output drags had 25 ms IPC throttling, `setNativeOutputVolume` and `setInputVolume` had **zero throttling**.
   - Worse, `setInputVolume` called `MicrophoneControl.setVolume()`, which on **every drag pixel** wrote CoreAudio HAL volume, read/mutated/wrote a `UserDefaults` dictionary plist to disk, wrote HAL mute, and performed a discarded trailing `readStatus()` HAL readback.
4. **40 Hz `AXIsProcessTrusted()` Mach IPC & Duplicate `publishState()` in `VolumeEngine`**:
   - `VolumeEngine.receive(_:)` called `publishState()` both inside `.volume`/`.step`/`.mute` helpers and again at the end of the `switch`, and `publishState()` called `AXIsProcessTrusted()` (a Mach IPC to `tccd`) on every single volume tick during slider drags.
   - `kAudioHardwarePropertyDevices` bursts (3–6 events in 50 ms on DisplayPort/Bluetooth plug-in) were uncoalesced, and `handleDeviceTopologyChange()` queried `currentDefault()` twice back-to-back.
5. **Silent Click-Drop Bug in `SmoothNativeSlider` After External Volume Changes**:
   - `Coordinator.lastSentValue` was never synchronized when `updateNSView` updated the slider from keyboard `F10–F12` keys or preset buttons, causing a subsequent click back to that previously dragged percentage to be filtered as a duplicate.
6. **Redundant Full-Buffer `memset` & Inner-Loop Pointer Math in `AudioGain.c`**:
   - `render()` unconditionally zeroed every output buffer with `memset` even before overwriting 100% of frames in steady-state playback, doubling memory traffic on the real-time audio IO thread, and recomputed channel pointer offsets inside the inner sample loop.
7. **Serial 19.5s Build Pipeline & Zero PR / CI Governance**:
   - `Scripts/build.sh` re-rendered 10 PNG app icons via interpreted Swift (`1.62s`) on every edit and compiled `RunTests` (`4.38s`), `DisplayVolumeEngine` (`5.82s`), and `DisplayVolume` (`6.62s`) sequentially (`19.51s` total before codesign).

---

## 3. Five First-Principles Root Causes Behind All Rework & Lag

Rather than isolated one-off bugs, almost every bug, rework round, and stutter traced back to **five structural root causes**:

1. **Missing Single Source of Truth & Diff-Before-Publish Discipline**:
   - UI + Background Engine + CoreAudio HAL form a 3-party asynchronous state system. Without equality-guarded `@Published` mutations, external-value coordinator sync, and explicit distinction between hardware states (`isAlive` vs `isRunningSomewhere` vs `callbackCount`), async echoes and periodic polling inevitably trigger slider jumps, idle CPU storms, or false reconnect loops.
2. **Treating Cross-Process System IPC as Zero-Cost Memory Reads on the Main Thread**:
   - CoreAudio HAL properties, `AXIsProcessTrusted()` (`tccd`), `UserDefaults` plist persistence, and `launchctl` subprocesses are cross-process Mach IPC / disk I/O. Putting them on unthrottled drag handlers, duplicated `onAppear` hooks, or synchronous launch paths directly turns small latencies into visible UI stutters.
3. **Drifting Away from Native macOS Control & Window-Compositing Semantics**:
   - Custom popups, nested disclosure menus, non-monochrome tints, default SwiftUI `Slider`, and layer-clipped `NSPanel` hosting views caused 3 consecutive UI rework rounds (Phase 0 + Batches 2, 3, 4). Starting from native AppKit/Control Center geometry eliminates rework upfront.
4. **Unverified SDK Symbols & Sparse Hardware Capability Matrices**:
   - macOS audio devices expose sparse HAL properties (DisplayPort has no output volume; Continuity iPhone mic has neither gain nor mute; USB mics often lack hardware mute). Assuming uniform capabilities or unverified SDK constants causes compile failures and broken controls.
5. **No Automated Anti-Regression Gate or Parallel Feedback Loop**:
   - Direct commits to `main` with a 20s serial build and no static/latency guardrails meant every new feature risked reintroducing previously solved anti-patterns.

---

## 4. First-Principles Fixes Landed in `v2.2.0` & Measured Before/After Results

| Metric / Failure Mode | Before (`v2.1.0`) | After (`v2.2.0`) | Root-Cause Fix |
| :--- | :--- | :--- | :--- |
| **Idle UI CPU & Hidden SwiftUI Redraws** | `1m 50.92s` / 13h idle; `pollFallback` + `PopoverView.body` every 5s | **`0.00s` CPU over 7s idle**; **0** hidden `PopoverView` samples | `assignIfChanged` on every `@Published` property; `StatusItemRenderKey` icon cache; 30s mtime-guarded heartbeat |
| **Popover Open HAL Latency** | `14.84 ms` avg (`21.67 ms` max) — **4× full scans** | **`4.49 ms` avg** — **1× single-pass scan** (**3.3× faster**) | `AudioDeviceCatalog.captureSnapshot()` + 120ms `refreshIfStale()` + direct `deviceID` switching + 60ms topology debounce |
| **Mic & Native Output Drag I/O** | Unthrottled HAL + per-pixel `UserDefaults` disk write + wasted readback | **20 ms throttled HAL**; **0 disk writes during drag**; **0 wasted readbacks** | `DispatchThrottleMath.shouldEmit` + `MicrophoneControl.applyVolume(..., persistPreMute: !isDragging)` |
| **Engine Drag Overhead** | 2× `publishState` + 40 Hz `AXIsProcessTrusted()` Mach IPC | **1× `publishState`**; **0 `AXIsProcessTrusted()` calls during drag** | `cachedAccessibilityTrusted` + early `return` in `receive(_:)` + cancellable `retryWorkItem` |
| **Real-Time Audio DSP (`AudioGain.c`)** | Full-buffer `memset` + inner-loop pointer math | **Zero redundant `memset`**; hoisted pointers + SIMD steady-state path | Split steady-state (`remaining == 0`) fast paths + tail-only zeroing + expanded `GainSelfTest()` |
| **Cold Launch Startup Blocking** | Synchronous `launchctl` + double SHA-256 on MainActor before icon | **Immediate menu bar icon**; async `.userInitiated` engine provisioning | Offloaded `EngineProvisioner.ensureInstalledAndRunning()` off MainActor |
| **Incremental Build Time (`build.sh`)** | `19.51s` (compile+icon+tests, serial; >21s with sign) | **`8.75s` end-to-end** (warm icon cache `0.03s`, parallel `swiftc`) (**2.4× faster**) | SHA-256 cached `AppIcon.icns` + parallel `RunTests` / `Engine` / `App` compilation |

---

## 5. Permanent Institutionalization (Preventing Repeat Cost)

All recurring lessons are now encoded directly in the repository so future sessions and contributors enforce them automatically:

- **Project Rules**: [`AGENTS.md`](../AGENTS.md) — concise architectural invariants, state-ownership rules, IPC/CPU budgets, and macOS privacy/UI contracts.
- **Automated Quality Gate**: [`Scripts/verify.sh`](../Scripts/verify.sh) — runs version lockstep check (`Info.plist == EngineInfo.plist`), 9 static anti-pattern guards (including `#if LIQUID_GLASS_SDK` compile-time portability caught immediately on our first `macos-15` GitHub Actions CI run!), parallel `-warnings-as-errors` build, unit + C DSP tests, strict codesign verification, `--self-test`, and `--bench` latency budgets.
- **GitHub Actions CI & PR Template**: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) and [`.github/pull_request_template.md`](../.github/pull_request_template.md) — runs `./Scripts/verify.sh` + DMG smoke packaging on macOS runners for every PR and push to `main`.
- **Reusable Project Skill**: [`.agents/skills/displayvolume-engineering/SKILL.md`](../.agents/skills/displayvolume-engineering/SKILL.md) — step-by-step engineering, debugging, profiling, and release workflow embedded directly in the repo.
