# "Hearing Aids" output device

A local build of the open-source **BlackHole** loopback driver (© Existential Audio Inc., GPL-3.0;
see LICENSE-BlackHole and UPSTREAM-COMMIT), renamed because modified builds may not use the BlackHole
name or branding. It gives macOS a "Hearing Aids" sound output. asha-service reads what's played to it
(from a hidden "Hearing Aids Monitor" input) and streams it to the aids over ASHA.

Change to the source (HearingAidsDriver.c): `kAudioDevicePropertySafetyOffset` returns a separate
`kSafety_Offset_Frame_Size` (0) instead of `kLatency_Frame_Size`, so the reported latency (for A/V sync)
adds no real delay. All other settings are build flags in build-driver.sh.

Built by the top-level `./build.sh` (or `driver/build-driver.sh` alone). Install: `sudo scripts/install-driver.sh`. Remove: `sudo scripts/uninstall-driver.sh`.

This directory's licence is GPL-3.0 (LICENSE-BlackHole). Please report problems with this build here, not to the BlackHole project.
