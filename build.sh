#!/bin/zsh
# build.sh — builds everything into ./build/. No Xcode needed, only the Command Line Tools
# (install them with:  xcode-select --install).
#
#   build/asha-probe      inspect / pair one hearing aid (sends no audio)
#   build/asha-tone       stream a quiet test tone to ONE aid
#   build/asha-stream     stream the Mac's audio to ONE aid
#   build/asha-binaural   stream to BOTH aids (test tone or the Mac's audio)
#   build/asha-service    the background service (normally installed by scripts/install.sh)
#   build/ashactl         command-line remote control for the service
#   build/ASHA.app        the menu-bar app
#   build/g722check       offline self-test of the audio codec (no Bluetooth)
#   build/capturecheck    offline self-test of audio capture (no Bluetooth)
#   driver/build/ASHA Hearing Aids.driver   the "Hearing Aids" sound output (see driver/README.md)
#
# Notes for readers new to this:
#  * Bluetooth programs get Info.plist embedded in them (a "section" of the program file),
#    because macOS only lets a program use Bluetooth if it explains why in that file.
#  * The G.722 audio codec is C code. clang compiles it to object files (.o), swiftc links
#    them in, and -import-objc-header lets Swift call the C functions.
#  * SDK = the system headers/libraries we compile against. Some Command Line Tools releases
#    ship a newer SDK than their Swift compiler can read, so we test which SDK works.
#    Override with:  SDK=/path/to/MacOSX.sdk ./build.sh

set -euo pipefail          # stop at the first error, treat unset variables as errors
cd "$(dirname "$0")"       # run from the repository folder, wherever we're called from
mkdir -p build/obj

# ---- 1. Pick an SDK that this Swift compiler can actually use -----------------------------
sdk_works() {
    # Compile a one-line program that imports the frameworks we need; success = usable SDK.
    echo 'import CoreBluetooth; import CoreAudio; import AVFoundation; import AppKit' > build/obj/sdkcheck.swift
    swiftc -sdk "$1" -typecheck build/obj/sdkcheck.swift >/dev/null 2>&1
}
if [[ -z "${SDK:-}" ]]; then
    CANDIDATES=("$(xcrun --show-sdk-path 2>/dev/null || true)")
    # Every versioned SDK installed with the Command Line Tools, newest first.
    CANDIDATES+=(${(On)$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null)})
    for c in "${CANDIDATES[@]}"; do
        [[ -n "$c" && -d "$c" ]] && sdk_works "$c" && { SDK="$c"; break; }
    done
fi
[[ -n "${SDK:-}" ]] || { echo "No macOS SDK works with this Swift compiler. Try: xcode-select --install"; exit 1; }
echo "Using SDK: $SDK"

# ---- 2. The C codec -------------------------------------------------------------------------
for f in g722_encode g722_decode; do
    clang -x c -c -O2 -Wall -isysroot "$SDK" g722/$f.c -o build/obj/$f.o
done

# ---- 3. The Swift programs ------------------------------------------------------------------
#   -swift-version 5      Swift 5 language rules (looser concurrency checks)
#   -O                    optimise
SWIFT_FLAGS=(-sdk "$SDK" -swift-version 5 -O -import-objc-header g722/g722_enc_dec.h)
PLIST_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist)
SHARED=(shared/*.swift)
CODEC=(build/obj/g722_encode.o build/obj/g722_decode.o)

build_tool() {   # build_tool <output name> <main.swift>
    swiftc "${SWIFT_FLAGS[@]}" "${PLIST_FLAGS[@]}" "${SHARED[@]}" "$2" "${CODEC[@]}" -o "build/$1"
    echo "Built: build/$1"
}
build_tool asha-probe    tools/probe/main.swift
build_tool asha-tone     tools/tone/main.swift
build_tool asha-stream   tools/stream/main.swift
build_tool asha-binaural tools/binaural/main.swift
build_tool asha-service  service/asha-service/main.swift
build_tool g722check     tests/g722check/main.swift
build_tool capturecheck  tests/capturecheck/main.swift

# ashactl and the menu app never touch Bluetooth or audio, so they don't need the shared code.
swiftc -sdk "$SDK" -swift-version 5 -O service/ashactl/main.swift -o build/ashactl
echo "Built: build/ashactl"

# ---- 4. The menu-bar app (an .app bundle is just a folder with a fixed layout) ---------------
APP=build/ASHA.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -sdk "$SDK" -swift-version 5 -O menu/main.swift -o "$APP/Contents/MacOS/ASHA"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ASHA</string>
  <key>CFBundleIdentifier</key><string>local.asha.menu</string>
  <key>CFBundleName</key><string>ASHA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <!-- Menu-bar only: no Dock icon. -->
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"     # "-" = ad-hoc signature, required for all code on Apple silicon
echo "Built: $APP"

# ---- 5. The "Hearing Aids" sound output driver ------------------------------------------------
SDK="$SDK" driver/build-driver.sh

echo
echo "All built. Next step: see README.md, \"Setup\"."
