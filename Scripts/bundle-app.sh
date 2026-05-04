#!/bin/bash
# Wraps the SwiftPM-built ClaudeToolApp executable into a Tango.app bundle
# with Info.plist, entitlements, and AppIcon.icns.
#
# Usage:
#   Scripts/bundle-app.sh [release|debug]   (default: release)
#
# Output: build/Tango.app

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build"
APP="${BUILD_DIR}/Tango.app"
SWIFT_BIN_NAME="ClaudeToolApp"   # internal SwiftPM target name (kept stable)
APP_BIN_NAME="TangoApp"          # bundled executable name (matches CFBundleExecutable)

cd "$ROOT"

echo "==> swift build -c ${CONFIG}"
swift build -c "$CONFIG" --product "$SWIFT_BIN_NAME"
swift build -c "$CONFIG" --product tango

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Bundling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
mkdir -p "${APP}/Contents/Helpers"

cp "${BIN_PATH}/${SWIFT_BIN_NAME}" "${APP}/Contents/MacOS/${APP_BIN_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "${BIN_PATH}/tango" "${APP}/Contents/Helpers/tango"

# Embed the icon if one has been generated.
if [[ -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc signing (override with: codesign --sign 'Developer ID Application: ...' --entitlements Resources/Tango.entitlements --options runtime ${APP})"
codesign --force --sign - --entitlements "${ROOT}/Resources/Tango.entitlements" "${APP}"

echo "==> Done: ${APP}"
echo "   Try:  open ${APP}"
echo "   CLI:  ${BIN_PATH}/tango --help"
