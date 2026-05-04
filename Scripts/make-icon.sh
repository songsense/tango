#!/bin/bash
# Generates Resources/AppIcon.icns from a programmatically-drawn icon.
# Requires Xcode tools (iconutil, swift).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="${ROOT}/build/AppIcon.iconset"
OUT="${ROOT}/Resources/AppIcon.icns"

mkdir -p "${ROOT}/build"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> Generating PNGs in $ICONSET"
swift "${ROOT}/Scripts/make-icon.swift" "$ICONSET"

echo "==> Compiling .icns"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "==> Done: $OUT"
ls -la "$OUT"
