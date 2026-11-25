#!/usr/bin/env bash
set -euo pipefail

# DisplayVolume First-Principles Anti-Regression & Quality Gate
# Codifies recurring failure modes discovered during the Nov 2026 retrospective:
#   1. Info.plist / EngineInfo.plist version drift
#   2. Deprecated / non-existent CoreAudio SDK constants
#   3. Unguarded @Published self-assignments causing idle CPU & hidden SwiftUI redraw storms
#   4. Unthrottled UserDefaults disk writes in continuous drag hot paths
#   5. OSD layer-clipping shadow artifact regressions
#   6. Microphone capture stream calls that would trigger the macOS privacy dot or Bluetooth HFP downgrade
#   7. Clean parallel build (-warnings-as-errors), unit tests, codesign, self-test, and HAL latency budgets

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

echo "=== 2. Static Anti-Pattern Audit ==="
python3 - <<'PY'
import pathlib, re, sys

root = pathlib.Path(".")
errors = []

audio_device = (root / "Sources/Shared/AudioDevice.swift").read_text()
# Guard against macOS 13 deprecated or non-existent CoreAudio transport constants
if re.search(r"\bkAudioDeviceTransportTypeContinuityCapture\b", audio_device):
    errors.append("AudioDevice.swift uses deprecated kAudioDeviceTransportTypeContinuityCapture (use Wired/Wireless)")
if "kAudioDeviceTransportTypeSPDIF" in audio_device:
    errors.append("AudioDevice.swift references non-existent kAudioDeviceTransportTypeSPDIF")

# Guard zero mic privacy dot & zero AirPods HFP downgrade invariant:
# Hardware mic/output controls must never open AVAudioEngine / AudioQueue / AVCaptureSession streams.
for forbidden in ("AVAudioEngine", "AVCaptureSession", "AudioQueueNewInput", "AVAudioRecorder"):
    if forbidden in audio_device:
        errors.append(f"AudioDevice.swift must not open capture streams ({forbidden}) — use HAL properties only")

# Guard OSD shadow-clipping invariant (no rectangle shadow artifacts in macOS Tahoe Liquid Glass)
osd = (root / "Sources/Engine/VolumeOSD.swift").read_text()
for required in ("shadowInset", "container.wantsLayer = false", "p.hasShadow = false"):
    if required not in osd:
        errors.append(f"VolumeOSD.swift missing anti-shadow-clipping invariant: `{required}`")

# Guard @Published diff-before-assign in DisplayVolumeApp.swift (prevents idle CPU / hidden SwiftUI redraws)
app_swift = (root / "Sources/App/DisplayVolumeApp.swift").read_text()
if "assignIfChanged(" not in app_swift:
    errors.append("DisplayVolumeApp.swift must guard @Published updates with assignIfChanged()")
if "StatusItemRenderKey" not in app_swift:
    errors.append("DisplayVolumeApp.swift must guard MenuBarIconRenderer with StatusItemRenderKey")
if "AudioDeviceCatalog.captureSnapshot()" not in app_swift:
    errors.append("DisplayVolumeApp.swift must use single-pass AudioDeviceCatalog.captureSnapshot()")

# Guard against calling MicrophoneControl.setVolume(...) inside setInputVolume drag hot path
m_input = re.search(r"func setInputVolume\([^)]*\)\s*\{(.*?)\n    \}", app_swift, re.S)
if not m_input:
    errors.append("Could not locate setInputVolume in DisplayVolumeApp.swift")
else:
    body = m_input.group(1)
    if "MicrophoneControl.setVolume(" in body:
        errors.append("setInputVolume must call MicrophoneControl.applyVolume(..., persistPreMute: !isDragging), not setVolume()")
    if "DispatchThrottleMath.shouldEmit" not in body:
        errors.append("setInputVolume must throttle HAL writes during active drag")

# Guard slider external-value coordinator sync invariant (prevents dropped clicks after keyboard/preset change)
components = (root / "Sources/App/VolumeComponents.swift").read_text()
if "syncExternalValue(" not in components:
    errors.append("VolumeComponents.swift must sync Coordinator.lastSentValue on external updateNSView updates")

# Guard engine watchdog silence stability & cached accessibility check
engine = (root / "Sources/Engine/VolumeEngine.swift").read_text()
if "isRunningSomewhere" not in engine:
    errors.append("VolumeEngine.swift watchdog must check device.isRunningSomewhere during idle silence")
if "cachedAccessibilityTrusted" not in engine:
    errors.append("VolumeEngine.swift must cache Accessibility trust instead of calling AXIsProcessTrusted() on every drag tick")

# Guard Liquid Glass SDK compile-time portability (macOS 15 Xcode 16 vs macOS 26+ SDK)
for f in ("Sources/Engine/VolumeOSD.swift", "Sources/App/VolumeComponents.swift"):
    src = (root / f).read_text()
    if (".glassEffect(" in src or ".buttonStyle(.glass)" in src) and "#if LIQUID_GLASS_SDK" not in src:
        errors.append(f"{f} uses macOS 26 Liquid Glass API without #if LIQUID_GLASS_SDK compile-time guard")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)
print("OK: All 9 first-principles static anti-pattern guards passed")
PY

echo "=== 3. Parallel Build, Unit Tests, Codesign & App Self-Test ==="
./Scripts/build.sh "$@"

echo "=== 4. Runtime HAL & IPC Latency Budget Check ==="
./build/DisplayVolume.app/Contents/MacOS/DisplayVolume --bench

echo "=== ALL VERIFICATION GATES PASSED ==="
