#!/bin/zsh
# install-driver.sh — add the "Hearing Aids" sound output. Run with:  sudo scripts/install-driver.sh
# Copies the driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio (sound stops for ~2 s).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo:  sudo $0"; exit 1; }
cd "$(dirname "$0")/.."
SRC="driver/build/ASHA Hearing Aids.driver"
[ -d "$SRC" ] || { echo "Run ./build.sh first."; exit 1; }
rm -rf "/Library/Audio/Plug-Ins/HAL/ASHA Hearing Aids.driver"
cp -R "$SRC" /Library/Audio/Plug-Ins/HAL/
chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/ASHA Hearing Aids.driver"
killall coreaudiod || true
echo "Installed. 'Hearing Aids' should now appear in System Settings > Sound > Output."
