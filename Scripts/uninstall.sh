#!/usr/bin/env bash
set -euo pipefail

UID_NUM="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/com.hazelkahlil.DisplayVolume.Engine.plist"
SUPPORT_DIR="$HOME/Library/Application Support/DisplayVolume"

launchctl bootout "gui/${UID_NUM}/com.hazelkahlil.DisplayVolume.Engine" 2>/dev/null || true
launchctl bootout "gui/${UID_NUM}" "$PLIST" 2>/dev/null || true
pkill -x DisplayVolume 2>/dev/null || true
pkill -x DisplayVolumeEngine 2>/dev/null || true

rm -f "$PLIST"
rm -rf "$SUPPORT_DIR"
rm -rf "/Applications/DisplayVolume.app" "$HOME/Applications/DisplayVolume.app"

echo "DisplayVolume uninstalled cleanly."
