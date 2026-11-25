## Summary

<!-- What changed and why from first principles? -->

## Verification Checklist

- [ ] `./Scripts/verify.sh` passed locally (static guards, `-warnings-as-errors`, `RunTests`, `--self-test`, `--bench`).
- [ ] **No main-thread IPC storms**: Any new HAL / TCC / `UserDefaults` / `launchctl` work is single-pass, throttled (`>= 20ms` during drag), debounced on topology bursts, or offloaded from startup.
- [ ] **No phantom SwiftUI redraws**: All `@Published` mutations in `VolumeController` use `assignIfChanged(...)` and status-bar redraws are guarded by `StatusItemRenderKey`.
- [ ] **Zero mic privacy dot & zero Bluetooth HFP downgrade**: Input controls use CoreAudio HAL properties only (never open an input capture stream).
- [ ] **Version lockstep**: If bumping versions, `Info.plist` and `EngineInfo.plist` match (`CFBundleShortVersionString` & `CFBundleVersion`).
- [ ] **Real-hardware / GUI verification** (when UI, OSD, hotkeys, or audio routing changed): verified live on macOS with external display & microphone.
