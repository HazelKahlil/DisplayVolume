#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d "build/DisplayVolume.app" ]]; then
  ./Scripts/build.sh
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
mkdir -p dist
DMG_NAME="DisplayVolume-v${VERSION}.dmg"
DMG_PATH="$ROOT_DIR/dist/${DMG_NAME}"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R build/DisplayVolume.app "$STAGE_DIR/DisplayVolume.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "DisplayVolume v${VERSION}" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created DMG: $DMG_PATH"
