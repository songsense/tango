#!/bin/bash
# Production build: signs with Developer ID, optionally notarizes, packages as DMG.
#
# Required env vars for signing:
#   DEVELOPER_ID_APPLICATION   e.g. "Developer ID Application: Your Name (TEAMID)"
# Optional env vars for notarization:
#   NOTARY_KEYCHAIN_PROFILE    notarytool keychain profile name
#
# Usage: Scripts/build-and-sign.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build"
APP="${BUILD_DIR}/Tango.app"
DMG="${BUILD_DIR}/Tango.dmg"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "WARN: DEVELOPER_ID_APPLICATION not set — falling back to ad-hoc signing."
    "$ROOT/Scripts/bundle-app.sh" release
    exit 0
fi

"$ROOT/Scripts/bundle-app.sh" release

echo "==> Re-signing with Developer ID"
codesign --force --options runtime --timestamp \
    --entitlements "${ROOT}/Resources/Tango.entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "${APP}/Contents/Helpers/tango"
codesign --force --options runtime --timestamp \
    --entitlements "${ROOT}/Resources/Tango.entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
rm -f "$DMG"
hdiutil create -volname "Tango" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "==> Submitting to Apple notary service"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> Done: $DMG"
