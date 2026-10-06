#!/bin/zsh
# install.sh — install the background service and the menu-bar app for your user (no sudo needed).
# Run ./build.sh first. Both start automatically at every login.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x build/asha-service ] && [ -d build/ASHA.app ] || { echo "Run ./build.sh first."; exit 1; }
UID_=$(id -u)
DEST="$HOME/Library/Application Support/ASHA"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/Applications" "$HOME/.local/bin"

# ---- The service: copied (so rebuilding doesn't disturb the running copy), started by launchd ----
launchctl bootout "gui/$UID_/local.asha.service" 2>/dev/null || true
cp build/asha-service build/ashactl "$DEST/"
ln -sf "$DEST/ashactl" "$HOME/.local/bin/ashactl"
cat > "$HOME/Library/LaunchAgents/local.asha.service.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.asha.service</string>
  <key>ProgramArguments</key><array><string>$DEST/asha-service</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Restart it if it crashes, but not after a clean "ashactl quit". -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <!-- Audio timing matters: ask for interactive (not background) scheduling. -->
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/asha-service.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/asha-service.log</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$UID_" "$HOME/Library/LaunchAgents/local.asha.service.plist"
echo "Service installed and started. Log: ~/Library/Logs/asha-service.log"

# ---- The menu-bar app ----
pkill -x ASHA 2>/dev/null || true
launchctl bootout "gui/$UID_/local.asha.menu" 2>/dev/null || true
rm -rf "$HOME/Applications/ASHA.app"; cp -R build/ASHA.app "$HOME/Applications/"
cat > "$HOME/Library/LaunchAgents/local.asha.menu.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.asha.menu</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/ASHA.app/Contents/MacOS/ASHA</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
launchctl bootstrap "gui/$UID_" "$HOME/Library/LaunchAgents/local.asha.menu.plist"
echo "Menu-bar app installed: look for the ear icon."
echo
echo "macOS may now ask 'asha-service' for Bluetooth and audio-recording permission: click Allow."
echo "Command line control:  ~/.local/bin/ashactl on|off|status|quit"
