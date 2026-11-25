#!/usr/bin/env bash
set -euo pipefail

# DisplayVolume First-Principles Anti-Regression & Security Gate
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "=== 1. Version Lockstep Audit (Info.plist == EngineInfo.plist) ==="
app_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
eng_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' EngineInfo.plist)"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
eng_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' EngineInfo.plist)"
[[ "$app_ver" == "$eng_ver" ]] || fail "Version mismatch: Info.plist=$app_ver vs EngineInfo.plist=$eng_ver"
[[ "$app_build" == "$eng_build" ]] || fail "Build mismatch: Info.plist=$app_build vs EngineInfo.plist=$eng_build"
echo "OK: Version $app_ver ($app_build) aligned across UI and Engine"

echo "=== 2. Static Anti-Pattern & Security Audit ==="
python3 - <<'PY'
import pathlib, re, sys

root = pathlib.Path(".")
errors = []

audio_device = (root / "Sources/Shared/AudioDevice.swift").read_text()
if re.search(r"\bkAudioDeviceTransportTypeContinuityCapture\b", audio_device):
    errors.append("AudioDevice.swift uses deprecated kAudioDeviceTransportTypeContinuityCapture")
if "kAudioDeviceTransportTypeSPDIF" in audio_device:
    errors.append("AudioDevice.swift references non-existent kAudioDeviceTransportTypeSPDIF")
for forbidden in ("AVAudioEngine", "AVCaptureSession", "AudioQueueNewInput", "AVAudioRecorder"):
    if forbidden in audio_device:
        errors.append(f"AudioDevice.swift must not open capture streams ({forbidden}) — use HAL properties only")
if "kAudioHardwarePropertyDefaultSystemOutputDevice" in audio_device:
    errors.append("AudioDevice.swift must not silently mutate kAudioHardwarePropertyDefaultSystemOutputDevice")

osd = (root / "Sources/Engine/VolumeOSD.swift").read_text()
for required in ("shadowInset", "container.wantsLayer = false", "p.hasShadow = false", "presentationGeneration"):
    if required not in osd:
        errors.append(f"VolumeOSD.swift missing required invariant: `{required}`")

app_swift = (root / "Sources/App/DisplayVolumeApp.swift").read_text()
# Reject inout-@Published anti-pattern (Swift copy-in/copy-out triggers objectWillChange even when unchanged!)
if "assignIfChanged(&" in app_swift:
    errors.append("DisplayVolumeApp.swift must not pass @Published properties as inout (triggers phantom objectWillChange)")
for required in ("StatusIconKey", "AudioDeviceCatalog.captureSnapshot()", "setCodeSigningRequirement", "InstallTransactionLock"):
    if required not in app_swift:
        errors.append(f"DisplayVolumeApp.swift missing required invariant: `{required}`")

m_input = re.search(r"func setInputVolume\([^)]*\)\s*\{(.*?)\n    \}", app_swift, re.S)
if not m_input:
    errors.append("Could not locate setInputVolume in DisplayVolumeApp.swift")
else:
    body = m_input.group(1)
    if "MicrophoneControl.setVolume(" in body:
        errors.append("setInputVolume must not call MicrophoneControl.setVolume() on drag hot path")
    if "DispatchThrottleMath.shouldEmit" not in body:
        errors.append("setInputVolume must throttle writes during active drag")

components = (root / "Sources/App/VolumeComponents.swift").read_text()
for required in ("syncExternalValue(", "invalidateSession("):
    if required not in components:
        errors.append(f"VolumeComponents.swift missing required invariant: `{required}`")

engine = (root / "Sources/Engine/VolumeEngine.swift").read_text()
for required in ("setConnectionCodeSigningRequirement", "routeQueue", "isRunningSomewhere", "cachedAccessibilityTrusted", "screensSleeping"):
    if required not in engine:
        errors.append(f"VolumeEngine.swift missing required invariant: `{required}`")
if "DistributedNotificationCenter.default().addObserver" in engine:
    errors.append("VolumeEngine.swift must accept commands strictly via authenticated XPC, never DistributedNotificationCenter")

ota = (root / "Sources/Shared/OTAManifest.swift").read_text()
for required in ("isValidSignature", "OTAArchiveSafety", "OTAInstallPreflight"):
    if required not in ota:
        errors.append(f"OTAManifest.swift missing security invariant: `{required}`")

updater = (root / "Sources/App/AppUpdater.swift").read_text()
if ".withoutDeletingBackupItem" not in updater or ".withoutDeletingBackupItem" not in app_swift:
    errors.append("replaceItemAt must pass .withoutDeletingBackupItem so rollback backups actually exist")

vol_model = (root / "Sources/Shared/VolumeModel.swift").read_text()
if "anchor apple generic" not in vol_model:
    errors.append("VolumeModel.swift XPC code signing requirement must pin `anchor apple generic`")

build_ota = (root / "Scripts/build_ota.sh").read_text()
if "--norsrc" not in build_ota:
    errors.append("Scripts/build_ota.sh must use `ditto --norsrc` to prevent __MACOSX archive entries")

# Guard Liquid Glass SDK compile-time portability
for f in ("Sources/Engine/VolumeOSD.swift", "Sources/App/VolumeComponents.swift"):
    src = (root / f).read_text()
    if (".glassEffect(" in src or ".buttonStyle(.glass)" in src) and "#if LIQUID_GLASS_SDK" not in src:
        errors.append(f"{f} uses macOS 26 Liquid Glass API without #if LIQUID_GLASS_SDK compile-time guard")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)
print("OK: All 16 first-principles static & security guards passed")
PY

echo "=== 3. Parallel Build, Unit Tests, Codesign & App Self-Test ==="
./Scripts/build.sh "$@"

echo "=== 4. Runtime HAL & IPC Latency Budget Check ==="
./build/DisplayVolume.app/Contents/MacOS/DisplayVolume --bench

echo "=== ALL VERIFICATION GATES PASSED ==="
