#!/bin/zsh
# uninstall-driver.sh — remove the "Hearing Aids" sound output. Run with:  sudo scripts/uninstall-driver.sh
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo:  sudo $0"; exit 1; }
rm -rf "/Library/Audio/Plug-Ins/HAL/ASHA Hearing Aids.driver"
killall coreaudiod || true
echo "Removed."
