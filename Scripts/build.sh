#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

sdk="$(xcrun --sdk macosx --show-sdk-path)"
arch="$(uname -m)"
target="${arch}-apple-macosx14.4"

echo "Building AppIcon.icns..."
mkdir -p "$scratch/AppIcon.iconset"
xcrun --sdk macosx swift Artwork/MakeIcon.swift "$scratch/AppIcon.iconset"
iconutil --convert icns "$scratch/AppIcon.iconset" --output "$scratch/AppIcon.icns"

echo "Compiling AudioGain.c..."
xcrun --sdk macosx clang -arch "$arch" -isysroot "$sdk" -mmacosx-version-min=14.4 \
  -O2 -std=c17 -Wall -Wextra -Werror -c Sources/Engine/AudioGain.c -o "$scratch/AudioGain.o"

echo "Running unit tests..."
xcrun --sdk macosx swiftc -sdk "$sdk" -target "$target" -O -warnings-as-errors \
  -import-objc-header Sources/Engine/AudioGain.h \
  Sources/Shared/Localization.swift \
  Sources/Shared/AudioDevice.swift \
  Sources/Shared/VolumeModel.swift \
  Sources/Engine/MediaKeyTap.swift \
  Tests/RunTests.swift \
  "$scratch/AudioGain.o" \
  -framework AppKit -framework CoreAudio -framework ApplicationServices -framework IOKit \
  -o "$scratch/RunTests"
"$scratch/RunTests"

echo "Building DisplayVolumeEngine.app..."
engine_bundle="$scratch/DisplayVolumeEngine.app"
mkdir -p "$engine_bundle/Contents/MacOS" "$engine_bundle/Contents/Resources"
cp EngineInfo.plist "$engine_bundle/Contents/Info.plist"
cp "$scratch/AppIcon.icns" "$engine_bundle/Contents/Resources/AppIcon.icns"
cp -R Resources/Engine/*.lproj "$engine_bundle/Contents/Resources/"

xcrun --sdk macosx swiftc -sdk "$sdk" -target "$target" -O -warnings-as-errors \
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
  -framework AppKit -framework SwiftUI -framework CoreAudio -framework Carbon \
  -framework ApplicationServices -framework IOKit \
  -o "$engine_bundle/Contents/MacOS/DisplayVolumeEngine"

echo "Building DisplayVolume.app..."
app_bundle="$scratch/DisplayVolume.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Helpers"
cp Info.plist "$app_bundle/Contents/Info.plist"
cp "$scratch/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app_bundle/Contents/Resources/"

xcrun --sdk macosx swiftc -sdk "$sdk" -target "$target" -O -warnings-as-errors \
  Sources/Shared/Localization.swift \
  Sources/Shared/AudioDevice.swift \
  Sources/Shared/VolumeModel.swift \
  Sources/Engine/MediaKeyTap.swift \
  Sources/App/MenuBarIconRenderer.swift \
  Sources/App/VolumeComponents.swift \
  Sources/App/PopoverView.swift \
  Sources/App/DisplayVolumeApp.swift \
  -framework AppKit -framework SwiftUI -framework CoreAudio -framework CryptoKit \
  -framework ServiceManagement -framework ApplicationServices -framework IOKit \
  -o "$app_bundle/Contents/MacOS/DisplayVolume"

# Prefer Apple Development cert so macOS TCC permissions (Audio Capture & Accessibility) persist across updates.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development:" | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [[ -n "${SIGN_ID:-}" && "${DISPLAYVOLUME_ADHOC_SIGN:-0}" != "1" ]]; then
  echo "Signing with identity: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" --identifier "com.hazelkahlil.DisplayVolume.Engine" "$engine_bundle"
  cp -R "$engine_bundle" "$app_bundle/Contents/Helpers/DisplayVolumeEngine.app"
  codesign --force --sign "$SIGN_ID" --identifier "com.hazelkahlil.DisplayVolume" "$app_bundle"
else
  echo "No Apple Development identity selected; using ad-hoc signature"
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

echo "Build complete: $PWD/build/DisplayVolume.app"
