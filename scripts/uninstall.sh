#!/bin/zsh
# uninstall.sh — remove the service and the menu-bar app (no sudo). Your paired-aid list in
# ~/.config/asha-mac is kept; delete that folder too for a completely clean slate.
UID_=$(id -u)
launchctl bootout "gui/$UID_/local.asha.service" 2>/dev/null
launchctl bootout "gui/$UID_/local.asha.menu" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.asha.service.plist" "$HOME/Library/LaunchAgents/local.asha.menu.plist" "$HOME/.local/bin/ashactl"
rm -rf "$HOME/Library/Application Support/ASHA" "$HOME/Applications/ASHA.app"
echo "Removed the service and the menu-bar app."
echo "Also installed? Remove with:  sudo scripts/uninstall-driver.sh   and   sudo scripts/disable-20ms.sh"
