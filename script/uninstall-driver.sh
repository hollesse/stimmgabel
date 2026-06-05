#!/bin/bash
# script/uninstall-driver.sh — Remove the Stimmgabel Audio Server Plugin
#
# Removes /Library/Audio/Plug-Ins/HAL/Stimmgabel.driver and restarts coreaudiod.
# The "Stimmgabel" device will disappear from all audio pickers after the restart.
#
# You will be prompted for your admin password exactly once.
# All running audio apps will experience a ~1 second interruption.

set -euo pipefail

DRIVER_DST="/Library/Audio/Plug-Ins/HAL/Stimmgabel.driver"

if [ ! -d "$DRIVER_DST" ]; then
    echo "Stimmgabel.driver is not installed at $DRIVER_DST — nothing to do."
    exit 0
fi

echo ">>> Removing $DRIVER_DST"
echo "    (You will be prompted for your admin password)"
sudo rm -rf "$DRIVER_DST"

echo ">>> Restarting coreaudiod..."
echo "    (All audio apps will pause for ~1 second)"
sudo killall coreaudiod

echo ">>> Done. The 'Stimmgabel' device has been removed."
