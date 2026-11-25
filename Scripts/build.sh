#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

t_start=$(python3 -c 'import time; print(f"{time.perf_counter():.3f}")')
elapsed_since() {
  python3 -c "import time; print(f'{time.perf_counter() - $1:.2f}s')"
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

sdk="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
arch="$(uname -m)"
target="${arch}-apple-macosx14.4"
swift_sdk_flags=()
if [[ "${sdk_major:-0}" -ge 26 ]]; then
  swift_sdk_flags+=(-D LIQUID_GLASS_SDK)
fi
cache_dir="$ROOT_DIR/build/.cache"
mkdir -p "$cache_dir"

# 1. Cached AppIcon.icns keyed by MakeIcon.swift SHA-256
icon_hash="$(shasum -a 256 Artwork/MakeIcon.swift | awk '{print $1}')"
cached_icns="$cache_dir/AppIcon-${icon_hash}.icns"
t_icon=$(python3 -c 'import time; print(f"{time.perf_counter():.3f}")')
if [[ -f "$cached_icns" ]]; then
  cp "$cached_icns" "$scratch/AppIcon.icns"
  echo "Using cached AppIcon.icns ($(elapsed_since "$t_icon"))"
else
  echo "Building AppIcon.icns..."
  mkdir -p "$scratch/AppIcon.iconset"
  xcrun --sdk macosx swift Artwork/MakeIcon.swift "$scratch/AppIcon.iconset"
  iconutil --convert icns "$scratch/AppIcon.iconset" --output "$scratch/AppIcon.icns"
  rm -f "$cache_dir"/AppIcon-*.icns
  cp "$scratch/AppIcon.icns" "$cached_icns"
  echo "Built AppIcon.icns ($(elapsed_since "$t_icon"))"
fi

# 2. Compile real-time C DSP object first (dependency of RunTests & Engine)
t_c=$(python3 -c 'import time; print(f"{time.perf_counter():.3f}")')
echo "Compiling AudioGain.c..."
xcrun --sdk macosx clang -arch "$arch" -isysroot "$sdk" -mmacosx-version-min=14.4 \
  -O2 -std=c17 -Wall -Wextra -Werror -c Sources/Engine/AudioGain.c -o "$scratch/AudioGain.o"
echo "Compiled AudioGain.c ($(elapsed_since "$t_c"))"

engine_bundle="$scratch/DisplayVolumeEngine.app"
mkdir -p "$engine_bundle/Contents/MacOS" "$engine_bundle/Contents/Resources"
cp EngineInfo.plist "$engine_bundle/Contents/Info.plist"
cp "$scratch/AppIcon.icns" "$engine_bundle/Contents/Resources/AppIcon.icns"
cp -R Resources/Engine/*.lproj "$engine_bundle/Contents/Resources/"

app_bundle="$scratch/DisplayVolume.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Helpers"
cp Info.plist "$app_bundle/Contents/Info.plist"
cp "$scratch/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app_bundle/Contents/Resources/"

# 3. Compile RunTests, DisplayVolumeEngine, and DisplayVolume in parallel across CPU cores
t_swift=$(python3 -c 'import time; print(f"{time.perf_counter():.3f}")')
echo "Compiling RunTests, DisplayVolumeEngine, and DisplayVolume in parallel..."

xcrun --sdk macosx swiftc -sdk "$sdk" -target "$target" -O -warnings-as-errors \
  -import-objc-header Sources/Engine/AudioGain.h \
  Sources/Shared/Localization.swift \
  Sources/Shared/AudioDevice.swift \
  Sources/Shared/VolumeModel.swift \
  Sources/Shared/OTAManifest.swift \
  Sources/Engine/MediaKeyTap.swift \
  Tests/RunTests.swift \
  "$scratch/AudioGain.o" \
  -framework AppKit -framework CoreAudio -framework CryptoKit -framework Security \
  -framework ApplicationServices -framework IOKit \
  -o "$scratch/RunTests" &
pid_tests=$!

xcrun --sdk macosx swiftc -sdk "$sdk" -target "$target" -O -warnings-as-errors ${swift_sdk_flags[@]+"${swift_sdk_flags[@]}"} \
  -import-objc-header Sources/Engine/AudioGain.h \
  Sources/Shared/Localization.swift \
  Sources/Shared/AudioDevice.swift \
  Sources/Shared/VolumeModel.swift \
  Sources/Engine/AudioRoute.swift \
  Sources/Engine/MediaKeyTap.swift \
  Sources/Engine/Hotkeys.swift \
  Sources/Engine/VolumeOSD.swift \
  Sources/Engine/VolumeEngine.swift \
  "$scratch/AudioGain.o" \
  -framework AppKit -framework SwiftUI -framework CoreAudio -framework Carbon -framework Security \
  -framework ApplicationServices -framework IOKit \
  -o "$engine_bundle/Contents/MacOS/DisplayVolumeEngine" &
pid_engine=$!

xcrun --sdk macosx swiftc -sdk "$sdk" -target "$target" -O -warnings-as-errors ${swift_sdk_flags[@]+"${swift_sdk_flags[@]}"} \
  Sources/Shared/Localization.swift \
  Sources/Shared/AudioDevice.swift \
  Sources/Shared/VolumeModel.swift \
  Sources/Shared/OTAManifest.swift \
  Sources/Engine/MediaKeyTap.swift \
  Sources/App/AppUpdater.swift \
  Sources/App/MenuBarIconRenderer.swift \
  Sources/App/VolumeComponents.swift \
  Sources/App/PopoverView.swift \
  Sources/App/DisplayVolumeApp.swift \
  -framework AppKit -framework SwiftUI -framework CoreAudio -framework CryptoKit -framework Security \
  -framework Combine -framework ServiceManagement -framework ApplicationServices -framework IOKit \
  -o "$app_bundle/Contents/MacOS/DisplayVolume" &
pid_app=$!

fail=0
wait "$pid_tests"  || fail=1
wait "$pid_engine" || fail=1
wait "$pid_app"    || fail=1
if [[ "$fail" -ne 0 ]]; then
  echo "Parallel Swift compilation failed." >&2
  exit 1
fi
echo "Parallel Swift compilation finished ($(elapsed_since "$t_swift"))"

echo "Running unit tests..."
"$scratch/RunTests"

# Select explicit Developer ID (with hardened runtime + timestamp), local Apple Development cert, or ad-hoc fallback.
SIGN_ID="${DISPLAYVOLUME_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" && "${DISPLAYVOLUME_ADHOC_SIGN:-0}" != "1" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application:" | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi
if [[ -z "$SIGN_ID" && "${DISPLAYVOLUME_ADHOC_SIGN:-0}" != "1" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development:" | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

sign_extra_flags=()
if [[ "$SIGN_ID" == Developer\ ID\ Application:* ]]; then
  sign_extra_flags+=(--options runtime --timestamp)
fi

if [[ -n "${SIGN_ID:-}" && "${DISPLAYVOLUME_ADHOC_SIGN:-0}" != "1" ]]; then
  echo "Signing with identity: $SIGN_ID"
  codesign --force ${sign_extra_flags[@]+"${sign_extra_flags[@]}"} --sign "$SIGN_ID" --identifier "com.hazelkahlil.DisplayVolume.Engine" "$engine_bundle"
  cp -R "$engine_bundle" "$app_bundle/Contents/Helpers/DisplayVolumeEngine.app"
  codesign --force ${sign_extra_flags[@]+"${sign_extra_flags[@]}"} --sign "$SIGN_ID" --identifier "com.hazelkahlil.DisplayVolume" "$app_bundle"
else
  echo "No signing certificate selected; using ad-hoc signature"
  codesign --force --sign - --identifier "com.hazelkahlil.DisplayVolume.Engine" "$engine_bundle"
  cp -R "$engine_bundle" "$app_bundle/Contents/Helpers/DisplayVolumeEngine.app"
  codesign --force --sign - --identifier "com.hazelkahlil.DisplayVolume" "$app_bundle"
fi

codesign --verify --strict "$app_bundle/Contents/Helpers/DisplayVolumeEngine.app"
codesign --verify --deep --strict "$app_bundle"
"$app_bundle/Contents/MacOS/DisplayVolume" --self-test

mkdir -p build
rm -rf build/DisplayVolume.app
mv "$app_bundle" build/DisplayVolume.app

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="${2:-$HOME/Applications}"
  mkdir -p "$INSTALL_DIR"
  echo "Installing to $INSTALL_DIR/DisplayVolume.app..."
  pkill -x DisplayVolume || true
  pkill -x RedmiVolume || true
  rm -rf "$INSTALL_DIR/DisplayVolume.app"
  cp -R build/DisplayVolume.app "$INSTALL_DIR/DisplayVolume.app"
  echo "Installed: $INSTALL_DIR/DisplayVolume.app"
fi

echo "Build complete in $(elapsed_since "$t_start"): $PWD/build/DisplayVolume.app"
