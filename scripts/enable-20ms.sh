#!/bin/zsh
# enable-20ms.sh — make macOS use the 20 ms Bluetooth connection interval that ASHA hearing aids need.
# Run with:  sudo scripts/enable-20ms.sh
#
# WHY (details in docs/HOW-IT-WORKS.md):
#   ASHA aids (at least Oticon Real) only accept audio on a 20 ms "connection interval" (how often the
#   Mac and the aid exchange radio packets). macOS never picks 20 ms by itself. Its Bluetooth daemon
#   (bluetoothd) has a hidden setting for it, but only reads it on Macs that report "internal
#   diagnostics", which is normally only true on Apple's own internal machines.
#
# WHAT THIS DOES (all reversible with scripts/disable-20ms.sh):
#   1. Creates /var/db/ConfigurationProfiles/Settings/com.apple.InternalDiagnostics.plist with
#      AppleInternal = true. That folder is protected by SIP (System Integrity Protection), so this
#      one step needs SIP turned OFF. You can (and should) turn SIP back ON afterwards; the file stays.
#   2. Writes the hidden bluetoothd setting: "low latency" = 20 ms.
#   3. Installs a tiny boot helper (LaunchDaemon). macOS checks the file in step 1 too early at boot,
#      so the helper does one "userspace reboot" (restarts everything except the kernel, about 30 s)
#      at each boot, so the check is redone. It never tries more than once per boot.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo:  sudo $0"; exit 1; }
cd "$(dirname "$0")/.."

FILE=/var/db/ConfigurationProfiles/Settings/com.apple.InternalDiagnostics.plist
PREFS=/Library/Preferences/com.apple.MobileBluetooth.debug

# ---- 1. The internal-diagnostics file ----
if [ -f "$FILE" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :AppleInternal' "$FILE" 2>/dev/null)" = "true" ]; then
    echo "1. $FILE already exists. OK."
else
    if ! csrutil status | grep -q disabled; then
        cat <<MSG
1. This step needs SIP (System Integrity Protection) turned OFF, once:
     a. Shut down. Hold the power button until "Loading startup options" appears. Choose Options.
     b. Utilities menu > Terminal. Type:  csrutil disable   then restart.
     c. Run this script again.
   Afterwards you can turn SIP back on the same way with:  csrutil enable
MSG
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :AppleInternal bool true" "$FILE"
    echo "1. Created $FILE"
fi

# ---- 2. The bluetoothd setting (milliseconds) ----
defaults write "$PREFS" LE -dict-add LeConnectionLatencyLowMinInterval -int 20 LeConnectionLatencyLowMaxInterval -int 20
echo "2. Set bluetoothd's low-latency interval to 20 ms."

# ---- 3. The boot helper ----
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel scripts/asha-bootfix.sh /usr/local/libexec/asha-bootfix.sh
cat > /Library/LaunchDaemons/local.asha.bootfix.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.asha.bootfix</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/asha-bootfix.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/var/log/asha-bootfix.log</string>
  <key>StandardErrorPath</key><string>/var/log/asha-bootfix.log</string>
</dict></plist>
PLIST
chown root:wheel /Library/LaunchDaemons/local.asha.bootfix.plist
chmod 644 /Library/LaunchDaemons/local.asha.bootfix.plist
echo "3. Installed the boot helper (runs at every boot; does nothing when already active)."

# ---- Is it active right now? ----
BITS=$(( ($(sysctl -n kern.osvariant_status) >> 6) & 3 ))
if [ "$BITS" -eq 3 ]; then
    pkill bluetoothd || true      # restart Bluetooth so it re-reads the setting (it restarts by itself)
    echo "Active now. Bluetooth was restarted to pick up the setting."
else
    echo
    echo "Not active yet: it needs a userspace reboot (all apps close; takes about 30 s)."
    printf "Do it now? Save your work first. [y/N] "
    read -r answer
    [[ "$answer" == [yY]* ]] && launchctl reboot userspace
    echo "OK. It will happen automatically at your next restart, or run:  sudo launchctl reboot userspace"
fi
