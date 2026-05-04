#!/bin/bash
set -euo pipefail

REPO="songsense/tango"
INSTALL_DIR="/usr/local/bin"
APP_DIR="/Applications"

# Detect architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
  echo "Error: Tango currently only supports Apple Silicon (arm64). Got: $ARCH" >&2
  exit 1
fi

# Find latest release
echo "Fetching latest Tango release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$LATEST" ]]; then
  echo "Error: could not fetch latest release from GitHub." >&2
  exit 1
fi

echo "Installing Tango $LATEST..."

TARBALL_URL="https://github.com/${REPO}/releases/download/${LATEST}/tango-macos-arm64.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$TARBALL_URL" -o "$TMP/tango.tar.gz"
tar -xzf "$TMP/tango.tar.gz" -C "$TMP"

# Install tango CLI
echo "Installing tango CLI to $INSTALL_DIR..."
if [[ -w "$INSTALL_DIR" ]]; then
  cp "$TMP/tango" "$INSTALL_DIR/tango"
  chmod +x "$INSTALL_DIR/tango"
else
  sudo cp "$TMP/tango" "$INSTALL_DIR/tango"
  sudo chmod +x "$INSTALL_DIR/tango"
fi

# Install Tango.app
echo "Copying Tango.app to $APP_DIR..."
if [[ -d "$APP_DIR/Tango.app" ]]; then
  rm -rf "$APP_DIR/Tango.app"
fi
cp -r "$TMP/Tango.app" "$APP_DIR/Tango.app"

echo ""
echo "Tango $LATEST installed."
echo ""
echo "Next steps:"
echo "  1. Open Tango:          open /Applications/Tango.app"
echo "  2. Grant permissions:   Microphone + Notifications when prompted"
echo "  3. Install Claude hooks: tango install-hooks"
echo "  4. Calibrate:           Menu bar → Tango → Calibrate"
