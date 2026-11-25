#!/usr/bin/env bash
set -euo pipefail

# Builds same-source DMG + OTA ZIP + Ed25519-signed ota-manifest.json + SHA256SUMS.txt
# Private signing key is read ONLY from macOS Keychain (never stored in repository).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

KEY_SERVICE="com.hazelkahlil.DisplayVolume.ota-signing-key"
KEY_ID="${DISPLAYVOLUME_OTA_KEY_ID:-dv-ota-2026-11}"
RELEASE_NOTES="${1:-DisplayVolume OTA release}"

./Scripts/verify.sh
./Scripts/package_dmg.sh

APP_BUNDLE="build/DisplayVolume.app"
APP_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
ARCH="$(uname -m)"
ZIP_NAME="DisplayVolume-v${APP_VER}-${ARCH}.zip"
ZIP_PATH="$ROOT_DIR/dist/${ZIP_NAME}"
DMG_NAME="DisplayVolume-v${APP_VER}.dmg"
DMG_PATH="$ROOT_DIR/dist/${DMG_NAME}"
MANIFEST_PATH="$ROOT_DIR/dist/ota-manifest.json"
SUMS_PATH="$ROOT_DIR/dist/SHA256SUMS.txt"

rm -f "$ZIP_PATH"
# Use --norsrc so ditto never emits __MACOSX/ AppleDouble entries that fail OTAArchiveSafety root checks.
ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# Verify zip contains strictly DisplayVolume.app entries with zero __MACOSX or escaping paths before signing!
python3 - "$ZIP_PATH" <<'PY'
import subprocess, sys
entries = subprocess.check_output(["/usr/bin/zipinfo", "-1", sys.argv[1]], text=True).splitlines()
bad = [e for e in entries if not e.startswith("DisplayVolume.app/") and e != "DisplayVolume.app" or ".." in e.split("/") or e.startswith("/")]
if bad or "DisplayVolume.app/Contents/MacOS/DisplayVolume" not in entries:
    print(f"ERROR: OTA zip archive failed structure verification. Bad entries: {bad[:5]}", file=sys.stderr)
    sys.exit(1)
print(f"Verified clean OTA zip structure ({len(entries)} entries, 0 __MACOSX entries)")
PY

ARCHIVE_SIZE="$(stat -f '%z' "$ZIP_PATH")"
ARCHIVE_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
DOWNLOAD_URL="https://github.com/HazelKahlil/DisplayVolume/releases/download/v${APP_VER}/${ZIP_NAME}"

PRIV_KEY_B64="$(security find-generic-password -s "$KEY_SERVICE" -a "$KEY_ID" -w 2>/dev/null || true)"
if [[ -z "$PRIV_KEY_B64" ]]; then
  echo "ERROR: Ed25519 private key not found in Keychain (service=$KEY_SERVICE, account=$KEY_ID)." >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/SignManifest.swift" <<'EOF'
import CryptoKit
import Foundation

@main
struct SignManifest {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let privB64 = env["OTA_PRIV_B64"],
              let privRaw = Data(base64Encoded: privB64),
              let version = env["OTA_VERSION"],
              let buildStr = env["OTA_BUILD"], let build = Int(buildStr),
              let arch = env["OTA_ARCH"],
              let sizeStr = env["OTA_SIZE"], let archiveSize = Int64(sizeStr),
              let sha256 = env["OTA_SHA256"],
              let url = env["OTA_URL"],
              let keyID = env["OTA_KEY_ID"],
              let notes = env["OTA_NOTES"],
              let outPath = env["OTA_OUT"] else {
            fputs("Missing OTA signing environment variables\n", stderr)
            exit(1)
        }

        let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privRaw)
        let now = Date()
        let iso = ISO8601DateFormatter()
        let expires = now.addingTimeInterval(86400 * 365) // 1-year manifest validity window

        let payload = OTAManifestPayload(
            schemaVersion: 1,
            keyID: keyID,
            channel: OTAConfig.channel,
            bundleID: VolumeIPC.suiteName,
            engineBundleID: VolumeIPC.engineBundleID,
            version: version,
            build: build,
            arch: arch,
            minMacOS: "14.4",
            archiveSize: archiveSize,
            archiveSHA256: sha256,
            downloadURL: url,
            publishedAt: iso.string(from: now),
            expiresAt: iso.string(from: expires),
            releaseNotes: notes
        )

        let canonical = try payload.canonicalData()
        let sig = try privKey.signature(for: canonical).base64EncodedString()
        let signed = SignedOTAManifest(payload: payload, signature: sig)

        // Immediately verify against embedded public trust root (using build-1 to validate full chain).
        _ = try OTAManifestVerifier.verify(signed, currentBuild: build - 1, currentArch: arch, now: now)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let outData = try encoder.encode(signed)
        try outData.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        print("Signed & verified OTA manifest: \(outPath)")
    }
}
EOF

sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$sdk" -target "${ARCH}-apple-macosx14.4" -O \
  Sources/Shared/Localization.swift \
  Sources/Shared/VolumeModel.swift \
  Sources/Shared/OTAManifest.swift \
  "$scratch/SignManifest.swift" \
  -framework CryptoKit -framework Security -o "$scratch/SignManifest"

OTA_PRIV_B64="$PRIV_KEY_B64" \
OTA_VERSION="$APP_VER" \
OTA_BUILD="$APP_BUILD" \
OTA_ARCH="$ARCH" \
OTA_SIZE="$ARCHIVE_SIZE" \
OTA_SHA256="$ARCHIVE_SHA256" \
OTA_URL="$DOWNLOAD_URL" \
OTA_KEY_ID="$KEY_ID" \
OTA_NOTES="$RELEASE_NOTES" \
OTA_OUT="$MANIFEST_PATH" \
"$scratch/SignManifest"

(cd dist && shasum -a 256 "$DMG_NAME" "$ZIP_NAME" "ota-manifest.json" > "$SUMS_PATH")
echo "=== OTA RELEASE ARTIFACTS READY ==="
ls -lh "$DMG_PATH" "$ZIP_PATH" "$MANIFEST_PATH" "$SUMS_PATH"
cat "$SUMS_PATH"
