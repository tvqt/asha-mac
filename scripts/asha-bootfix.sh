#!/bin/sh
# asha-bootfix.sh — runs ONCE at every boot, as root (installed by install-bootfix.sh).
#
# Why: bluetoothd only applies our 20 ms setting when macOS reports "internal diagnostics",
# and macOS decides that ONCE per boot, too early to see our settings file, so it records NO.
# A "userspace reboot" (restart everything except the kernel) re-checks with the file
# readable, so it records YES. See docs/FINDINGS.md, "Internal-diagnostics: WORKING via userspace reboot".
#
# Safety against loops: it only ever tries once per kernel boot (kern.boottime does not change
# on a userspace reboot), and does nothing if the settings file is missing or the status is already YES.

FILE=/var/db/ConfigurationProfiles/Settings/com.apple.InternalDiagnostics.plist
MARK=/var/db/asha-bootfix.boottime
[ -f "$FILE" ] || exit 0

STATUS=$(sysctl -n kern.osvariant_status)
BITS=$(( (STATUS >> 6) & 3 ))          # bits 6-7 = internal_diags_profile: 3 = YES, 2 = NO
[ "$BITS" -eq 3 ] && { logger "asha-bootfix: internal diagnostics already active"; exit 0; }

BOOT=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')
[ "$(cat "$MARK" 2>/dev/null)" = "$BOOT" ] && { logger "asha-bootfix: already tried this boot, giving up"; exit 0; }
echo "$BOOT" > "$MARK"

logger "asha-bootfix: internal diagnostics not active; doing a userspace reboot"
sleep 3
launchctl reboot userspace
