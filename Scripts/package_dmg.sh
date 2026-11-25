#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d "build/DisplayVolume.app" ]]; then
  ./Scripts/build.sh
fi

# Always read versions from the actual built bundles and verify strict lockstep with source plists.
SRC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
SRC_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
APP_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/DisplayVolume.app/Contents/Info.plist)"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/DisplayVolume.app/Contents/Info.plist)"
ENG_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/DisplayVolume.app/Contents/Helpers/DisplayVolumeEngine.app/Contents/Info.plist)"
ENG_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/DisplayVolume.app/Contents/Helpers/DisplayVolumeEngine.app/Contents/Info.plist)"

if [[ "$APP_VER" != "$SRC_VER" || "$APP_BUILD" != "$SRC_BUILD" || "$ENG_VER" != "$APP_VER" || "$ENG_BUILD" != "$APP_BUILD" ]]; then
  echo "ERROR: Built bundle version mismatch (src=$SRC_VER/$SRC_BUILD, app=$APP_VER/$APP_BUILD, engine=$ENG_VER/$ENG_BUILD). Re-run ./Scripts/build.sh first." >&2
  exit 1
fi

codesign --verify --strict build/DisplayVolume.app/Contents/Helpers/DisplayVolumeEngine.app
codesign --verify --deep --strict build/DisplayVolume.app

mkdir -p dist
DMG_NAME="DisplayVolume-v${APP_VER}.dmg"
DMG_PATH="$ROOT_DIR/dist/${DMG_NAME}"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R build/DisplayVolume.app "$STAGE_DIR/DisplayVolume.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "DisplayVolume v${APP_VER}" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created DMG: $DMG_PATH (v${APP_VER}, build ${APP_BUILD})"
