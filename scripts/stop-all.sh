#!/bin/zsh
# stop-all.sh — EMERGENCY STOP: kill every asha program at once (no sudo).
# Audio to the aids stops immediately, and if your Mac's speakers were muted by a capture, they come back.
# The background service restarts by itself only if it crashed; after this it stays stopped
# until you log in again or run:  launchctl kickstart gui/$(id -u)/local.asha.service
launchctl bootout "gui/$(id -u)/local.asha.service" 2>/dev/null
pkill -f 'asha-(probe|tone|stream|binaural|service)' && echo "Stopped." || echo "Nothing was running."
