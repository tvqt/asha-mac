#!/bin/zsh
# check.sh — show whether each piece of the setup is in place (no sudo, changes nothing).
ok()  { print -P "  %F{green}OK%f   $1"; }
bad() { print -P "  %F{red}NO%f   $1"; }
echo "asha-mac setup check"
csrutil status | grep -q disabled && echo "  --   SIP is OFF (fine during setup; turn it back on afterwards)" || echo "  --   SIP is on"
[ -f /var/db/ConfigurationProfiles/Settings/com.apple.InternalDiagnostics.plist ] && ok "internal-diagnostics file exists" || bad "internal-diagnostics file missing (sudo scripts/enable-20ms.sh)"
BITS=$(( ($(sysctl -n kern.osvariant_status) >> 6) & 3 ))
[ "$BITS" -eq 3 ] && ok "internal diagnostics ACTIVE this boot" || bad "internal diagnostics not active this boot (sudo launchctl reboot userspace)"
V=$(defaults read /Library/Preferences/com.apple.MobileBluetooth.debug LE 2>/dev/null | grep -c "Interval = 20")
[ "$V" -eq 2 ] && ok "bluetoothd 20 ms setting" || bad "bluetoothd 20 ms setting missing (sudo scripts/enable-20ms.sh)"
[ -f /Library/LaunchDaemons/local.asha.bootfix.plist ] && ok "boot helper installed" || bad "boot helper not installed (sudo scripts/enable-20ms.sh)"
K="$HOME/.config/asha-mac/known-aids.json"
for s in left right; do
    grep -q "\"$s\"" "$K" 2>/dev/null && ok "$s aid paired" || bad "$s aid not paired yet (build/asha-probe $s)"
done
[ -d "/Library/Audio/Plug-Ins/HAL/ASHA Hearing Aids.driver" ] && ok "'Hearing Aids' sound output installed" || echo "  --   'Hearing Aids' sound output not installed (optional: sudo scripts/install-driver.sh)"
launchctl print "gui/$(id -u)/local.asha.service" >/dev/null 2>&1 && ok "background service loaded" || echo "  --   background service not installed (optional: scripts/install.sh)"
pgrep -x ASHA >/dev/null && ok "menu-bar app running" || echo "  --   menu-bar app not running"
