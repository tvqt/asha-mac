# Findings

Research notes from building asha-mac (October 2026). Test setup: MacBook Air M1 (2020, Bluetooth chip BCM4378),
macOS 26.5.2 (25F84), Oticon Real 1 hearing aids (firmware rel_6.1_29.0). Protocol details were checked against
[Google's ASHA spec](https://source.android.com/docs/core/connect/bluetooth/asha), Android's implementation
(AOSP `packages/modules/Bluetooth`, `system/bta/hearing_aid/hearing_aid.cc`) and
[asha_pipewire_sink](https://github.com/thewierdnut/asha_pipewire_sink).

Code comments refer here when something needs more context than a comment can hold.

## Verified protocol facts

- Service `0xFDF0`. Characteristics:
  - ReadOnlyProperties `6333651e-c481-4a3e-9169-7c902aad37bb` (17 bytes, little-endian)
  - AudioControlPoint `f0d4de7e-4a88-476c-9d9f-1937b0996cc0`
  - AudioStatus `38663f1a-e711-4cac-b641-326b56404837` (notify)
  - Volume `00e4ca9e-ab14-41e4-8823-f9e70c7e91df`
  - LE_PSM_OUT `2d410339-82b6-42aa-b34e-e2e01df8cc1a`
- Start is `01 01 00 <vol> <otherstate>`, written **with** response. The codec byte is the codec **ID**: 1 = G.722 at 16 kHz.
  It is not the bitmask value `0x0002` from ReadOnlyProperties.
- Status is `03 02 <interval in 1.25 ms units>`, written without response. The spec text shows only `03 02`;
  Android and Linux also send the interval byte.
- Stop is `02`. Volume is one signed byte from −128 (mute) to 0. At 0, a 0 dBFS sine represents a "100 dB SPL input equivalent".
- Never stream before AudioStatus notifies `00`. Sending audio before the acknowledgement makes the aid hang up within about 90 ms.
- Each packet is `[seq]` + G.722 for exactly one interval (8 bytes per ms, so 160 bytes for 20 ms). One L2CAP SDU carries one packet.
  The HCI trace confirms it: every audio PDU is 163 bytes (2-byte SDU length + seq + 160).
- L2CAP: MTU 248, MPS 247, **8 initial credits**, and the aid returns 1 credit per packet it consumes.
- Battery: the aids' MFi service contains a characteristic `24e1dff3-ae90-41bf-bfbd-2cf8df42bf87` holding a level from 0 to 10
  (name and scaling from asha_pipewire_sink).

## What the aids actually do

1. **They don't advertise ASHA.** Adverts carry only Apple's MFi hearing service (`7D74F4BD-C74A-4431-862C-CCE884371592`)
   and manufacturer data. `FDF0` appears in GATT only after connecting. Once paired, the aid advertises only its name.
2. **Pairing:** reading ReadOnlyProperties fails with "insufficient authentication". macOS then pairs on its own
   ("Just Works") and shows a pop-up. The bond is stable afterwards.
3. **Link:** 2M PHY, data length 251, ATT MTU 247, PSM 128, RenderDelay 89 ms.
4. **Interval 10, 15 or 30 ms:** the Start write is acknowledged at the protocol level, no AudioStatus arrives, and the aid
   disconnects 2.1 s later (HCI reason 0x13, "Remote User Terminated").
5. **Interval 20 ms:** AudioStatus `00` arrives within about 60 ms and streaming works. So far as is known, this
   "20 ms or nothing" behaviour hadn't been documented anywhere before.
6. **The aid never asks for 20 ms.** A full HCI trace shows no LL Connection Parameter Request and no L2CAP Connection
   Parameter Update Request. It silently requires 20 ms.
7. **Busy with a phone:** if the aid is streaming from a phone, it refuses the L2CAP connection with
   "No Resources Available". CoreBluetooth doesn't report this to the app, which just waits, so the tools time out after 10 s with a hint.
8. Both aids accept a partner that joins mid-stream with the current shared sequence number.

## Getting 20 ms on macOS

See [HOW-IT-WORKS.md › The 20 ms problem](HOW-IT-WORKS.md#the-20-ms-problem) for the working recipe. Notes:

- Stock latency levels for `setDesiredConnectionLatency` (bluetoothd's ranges): 0 = 10–30 ms, 1 = 100–120 ms,
  2 = 290–320 ms. The controller picked the top of whatever range it was given, so only a range whose maximum is 20 helps.
- The `LeConnectionLatencyLow*` values are **milliseconds**. 16 produced 15 ms (rounded down to a multiple of 1.25).
  bluetoothd ignores values below 8.
- The internal-diagnostics answer is cached in `kern.osvariant_status`. Per xnu, only launchd can set it, once, and a userspace
  reboot resets it. Bits 6–7: 3 = yes, 2 = no.
- A 10 ms link was achieved (override = 10), but Oticon Real refused audio on it, so 20 ms is the floor for these aids.

## Dead ends

So nobody repeats them:

- **Private connect options** `kCBConnectOptionOverrideMin/MaxCIFrames`: ignored for third-party apps.
- **`DebugOverrideConnection*`** and top-level `LeConnectionLatency*` keys in `com.apple.bluetooth`: no effect.
- **Raw HCI through IOBluetooth** (`BluetoothHCISendRawCommand`, `-[IOBluetoothHostController BluetoothHCILEConnectionUpdate:…]`):
  still exported, but **stubs** on macOS 26. They return 0 and do nothing. An earlier project
  ([MacASHAStreamerApp](https://github.com/hxk1633/MacASHAStreamerApp)) stopped at the same point.
- **MIDI v2 latency path** in bluetoothd: only for MIDI devices, and behind the same internal-diagnostics gate.
- **Connection "use cases" / L2CAP priority:** these govern connection limits and scheduling, not the interval.
- **Apple's own MFi hearing support on base M1:** Apple supports every Apple-silicon Mac *except* the base-M1 models, all of which use the
  BCM4378 chip. On this Mac, System Settings shows "The settings for Hearing Devices are not available."
  The feature flag `Accessibility/MFi_HearingAids` is already on, and no model list or simple switch was found. The MFi client lives in
  HearingUtilities.framework, used by the `heard` daemon. The gate looks like it's tied to the chip, but the exact check wasn't located.
- **Linux in a VM:** the internal Bluetooth is PCIe, and VMs can pass through only USB, so that route needs a USB dongle.
- **PacketLogger GUI** recorded nothing. Its command-line tool works when run as root (`scripts/capture-hci.sh`).

## Other implementations

- Android: the reference. It uses 20 ms in practice.
- Linux: [asha_pipewire_sink](https://github.com/thewierdnut/asha_pipewire_sink), BlueZ/PipeWire work. Both use 20 ms.
- [Pico-ASHA](https://github.com/shermp/Pico-ASHA) (Raspberry Pi Pico W dongle): fixed 20 ms interval.
- Windows: blocked, because the public Bluetooth stack has no L2CAP CoC.

## Practical notes

- In zsh, `log` is a shell builtin. Use `/usr/bin/log show --predicate 'process == "bluetoothd"'` for Bluetooth logs.
  They show intervals, PHY, MTUs, pairing and disconnect reasons.
- Some Command Line Tools releases ship an SDK newer than their Swift compiler. `build.sh` picks one that works.
- A process tap captures audio **before** the system volume, so the volume keys do nothing to it. That's why the service maps the
  volume keys onto ASHA volume.
- Pressing Ctrl-Z *suspends* a program. A suspended capture that mutes the speakers leaves them silent. All tools now treat
  Ctrl-Z like Ctrl-C.
- An aid stuck in a bad state (for example, L2CAP connect hanging for a minute) recovers when restarted (battery door or charger).
- The quietest in-ear setting (−30 dBFS tone at volume −127) was still easily audible, while outside the ear only much louder settings
  were. Keep the aids out of your ears for first tests, and expect them to sound much louder once in.
- Volume 0 is uncomfortable for music but useful for quiet speech, such as a soft-spoken person on a call. So the volume keys
  reach 0 by default, and `--max-volume` caps it for anyone who wants that.
