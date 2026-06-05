#!/bin/bash
# script/install-driver.sh — Install the Stimmgabel Audio Server Plugin
#
# Copies Stimmgabel.driver from inside dist/Stimmgabel.app into
# /Library/Audio/Plug-Ins/HAL/ and restarts coreaudiod.
#
# You will be prompted for your admin password exactly once.
# All running audio apps will experience a ~1 second interruption
# while coreaudiod restarts.
#
# Usage:
#   ./script/install-driver.sh                   (uses dist/Stimmgabel.app)
#   APP_PATH=/path/to/Stimmgabel.app ./script/install-driver.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$REPO_ROOT/dist/Stimmgabel.app}"
DRIVER_SRC="$APP_PATH/Contents/Resources/Stimmgabel.driver"
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver"

if [ ! -d "$DRIVER_SRC" ]; then
    echo "ERROR: Driver not found at $DRIVER_SRC" >&2
    echo "       Run ./script/build first." >&2
    exit 1
fi

echo ">>> Installing Stimmgabel.driver to $DRIVER_DST"
echo "    (You will be prompted for your admin password)"
sudo cp -R "$DRIVER_SRC" "$DRIVER_DST"

echo ">>> Removing quarantine attribute (if present)"
sudo xattr -dr com.apple.quarantine "$DRIVER_DST" 2>/dev/null || true

echo ">>> Restarting coreaudiod..."
echo "    (All audio apps will pause for ~1 second)"
sudo killall coreaudiod

echo ">>> Done. The 'Stimmgabel' input device should now appear in:"
echo "    - Audio MIDI Setup (open it from Applications/Utilities/)"
echo "    - Any app's audio input picker (Zoom, QuickTime, etc.)"
