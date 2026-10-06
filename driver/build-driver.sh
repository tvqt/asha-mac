#!/bin/zsh
# build-driver.sh — build "ASHA Hearing Aids.driver", a Core Audio output device for the ASHA service.
#
# It is the open-source BlackHole loopback driver (GPL-3, github.com/ExistentialAudio/BlackHole, commit in
# UPSTREAM-COMMIT), built under a different name, with one source change (separate safety offset, see
# HearingAidsDriver.c) and these build settings:
#   * visible device "Hearing Aids": OUTPUT only (no confusing "Hearing Aids" microphone)
#   * hidden second device "Hearing Aids Monitor": INPUT only; asha-service reads the audio from it
#   * volume slider exists (so the Mac's volume keys work and asha-service can read it) but is NOT
#     applied to the audio: asha-service sends it to the aids as their ASHA volume (no double volume)
#   * reports 130 ms of output latency (6240 frames at 48 kHz) so video players delay the picture
#     to match the hearing aids; adds NO real delay (safety offset 0)
# Ad-hoc signed (codesign -s -), which Apple silicon requires for all code.
set -euo pipefail
cd "$(dirname "$0")"
SDK=${SDK:-$(xcrun --show-sdk-path)}   # build.sh passes the SDK it chose
OUT="build/ASHA Hearing Aids.driver"
LATENCY_FRAMES=${LATENCY_FRAMES:-6240}
rm -rf build && mkdir -p "$OUT/Contents/MacOS"

clang -bundle -O2 -Wno-format-extra-args -arch "$(uname -m)" -mmacosx-version-min=12.0 -isysroot "$SDK" \
  -D'kDriver_Name="ASHA Hearing Aids"' \
  -D'kPlugIn_BundleID="local.asha.HearingAidsDriver"' \
  -D'kPlugIn_Icon=""' \
  -D'kHas_Driver_Name_Format=false' \
  -D'kDevice_Name="Hearing Aids"' \
  -D'kDevice2_Name="Hearing Aids Monitor"' \
  -D'kManufacturer_Name="asha-mac (modified build of BlackHole)"' \
  -D'kDevice_HasInput=false' -D'kDevice_HasOutput=true' \
  -D'kDevice2_IsHidden=true' -D'kDevice2_HasInput=true' -D'kDevice2_HasOutput=false' \
  -D'kEnableVolumeControl=false' \
  -D"kLatency_Frame_Size=$LATENCY_FRAMES" -D'kSafety_Offset_Frame_Size=0' \
  -D'kNumber_Of_Channels=2' -D'kSampleRates=48000' \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  HearingAidsDriver.c -o "$OUT/Contents/MacOS/HearingAidsDriver"

# A new, unique factory UUID so this can never collide with a real BlackHole install.
FACTORY=8f1c7e2a-5b3d-4c6e-9a0b-0a5a5a1d0001
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>HearingAidsDriver</string>
  <key>CFBundleIdentifier</key><string>local.asha.HearingAidsDriver</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ASHA Hearing Aids</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFPlugInFactories</key><dict><key>$FACTORY</key><string>BlackHole_Create</string></dict>
  <!-- 443ABAB8-…: Apple's fixed type ID for an AudioServerPlugIn (a Core Audio driver). -->
  <key>CFPlugInTypes</key><dict><key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>$FACTORY</string></array></dict>
</dict></plist>
PLIST
codesign --force --sign - "$OUT"
echo "Built: driver/$OUT (reported latency $LATENCY_FRAMES frames)"
