#!/bin/zsh
# disable-20ms.sh — undo scripts/enable-20ms.sh. Run with:  sudo scripts/disable-20ms.sh
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo:  sudo $0"; exit 1; }
FILE=/var/db/ConfigurationProfiles/Settings/com.apple.InternalDiagnostics.plist
PREFS=/Library/Preferences/com.apple.MobileBluetooth.debug.plist

launchctl bootout system/local.asha.bootfix 2>/dev/null
rm -f /Library/LaunchDaemons/local.asha.bootfix.plist /usr/local/libexec/asha-bootfix.sh /var/db/asha-bootfix.boottime
echo "Removed the boot helper."

for k in LeConnectionLatencyLowMinInterval LeConnectionLatencyLowMaxInterval; do
    /usr/libexec/PlistBuddy -c "Delete :LE:$k" "$PREFS" 2>/dev/null
done
pkill bluetoothd
echo "Removed the bluetoothd setting (Bluetooth restarted)."

if [ -f "$FILE" ]; then
    if rm -f "$FILE" 2>/dev/null; then
        echo "Removed $FILE. Restart the Mac to finish."
    else
        echo "Could not remove $FILE: SIP protects it. Turn SIP off (Recovery > Terminal > csrutil disable),"
        echo "run this script again, then turn SIP back on (csrutil enable)."
        echo "(Without the boot helper, the file has no effect after a normal restart anyway.)"
    fi
fi
