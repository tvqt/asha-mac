#!/bin/zsh
# capture-hci.sh — record a full Bluetooth HCI trace (every packet between macOS and the
# Bluetooth chip) using Apple's PacketLogger command-line tool. Needs administrator rights:
#     sudo scripts/capture-hci.sh
# PacketLogger comes with Apple's "Additional Tools for Xcode" (developer.apple.com/download/all):
# copy PacketLogger.app into /Applications.
#
# PRIVACY: a trace contains your aids' Bluetooth addresses AND their pairing keys. Never share or
# commit traces/ (it is in .gitignore). Share only the lines you need, with addresses removed.
# Leave it running while you do the test in another Terminal window, then press Ctrl-C.
# HCI = Host Controller Interface, the command/event protocol between macOS and the radio chip.
# Output: traces/<date-time>.pklg (open in PacketLogger.app) + a decoded .txt copy.
set -u
cd "$(dirname "$0")/.."
mkdir -p traces
PL=/Applications/PacketLogger.app/Contents/Resources/packetlogger
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="traces/$STAMP.pklg"
echo "Recording to $OUT … press Ctrl-C to stop."
"$PL" convert -o "$OUT" &          # record in the background…
PL_PID=$!
trap 'kill -INT $PL_PID 2>/dev/null' INT   # …so Ctrl-C stops only the recorder, not this script
wait $PL_PID; wait $PL_PID 2>/dev/null
trap - INT
# After Ctrl-C: decode to text (timestamp, name, handle, direction, short + full description), readable by the user.
"$PL" convert -i "$OUT" -o "traces/$STAMP.txt" -f mnhdsf
chown "${SUDO_USER:-$USER}" "$OUT" "traces/$STAMP.txt" 2>/dev/null
echo "Saved $OUT and traces/$STAMP.txt"
