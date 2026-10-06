# How asha-mac works

This explains the moving parts for someone who knows some programming but not Bluetooth or audio.
The research behind it, including everything that *didn't* work, is in [FINDINGS.md](FINDINGS.md).

## The pieces

```
 apps ──▶ "Hearing Aids" output (driver/) ──▶ hidden "Hearing Aids Monitor" input
                                                    │
                                    asha-service (service/, shared/)
              48 kHz → 16 kHz → ring buffer → limiter → hard clamp → G.722
                                 │                        │
                         L2CAP channel             L2CAP channel
                                 ▼                        ▼
                             left aid                 right aid

 menu-bar app (menu/) and ashactl ◀── status.json / notifications ──▶ asha-service
 boot helper (scripts/asha-bootfix.sh) ── makes the 20 ms setting active after each restart
```

| Part | Where | Job |
|---|---|---|
| Protocol constants | `shared/Asha.swift` | UUIDs, command bytes, packet sizes. Each value is checked against the spec, Android, and a Linux implementation. |
| One aid's connection | `shared/AidLink.swift` | Connect, discover, subscribe, open the audio channel, start/stop, send packets, read the battery. |
| Both aids together | `shared/BinauralStreamer.swift`, `shared/AshaService.swift` | Shared sequence numbers, telling each aid about the other, reconnecting. |
| Audio capture | `shared/SystemAudio.swift` | Read the Hearing Aids Monitor input (or a Core Audio process tap), resample, buffer, limit. |
| Safety limits | `shared/Tone.swift` (`enum Safety`) | Ceilings and volume ranges that every path obeys. |
| Volume keys | `shared/VolumeKeys.swift` | Watch the Mac's volume and mute and convert them to ASHA volume. |
| Codec | `g722/`, `shared/G722.swift` | Android's G.722 encoder, called from Swift. |

## ASHA in five steps

Terms: **BLE** = Bluetooth Low Energy. **GATT** = BLE's system of named values ("characteristics") grouped
into "services", each with a UUID. **L2CAP CoC** = a connection-oriented channel, a data pipe a bit like a TCP
socket, opened on a "PSM" (its port number).

1. **Connect and pair.** Oticon aids don't advertise the ASHA service (UUID `FDF0`). They advertise Apple's MFi
   hearing service instead, so `asha-probe` looks for that, connects, and *then* finds `FDF0` in the GATT database.
   Reading the aid's properties triggers pairing.
2. **Read `ReadOnlyProperties`** (17 bytes): left or right, the pair's shared ID ("HiSyncId"), and the supported codecs.
   **Read `LE_PSM_OUT`** to learn which PSM to open.
3. **Open the L2CAP channel** on that PSM and subscribe to `AudioStatus`.
4. **Write to `AudioControlPoint`:**
   - `03 02 10`: "connection parameters updated, interval = 16 × 1.25 ms"
   - Volume (one signed byte: −128 = mute, −127 quietest, 0 loudest; 0.375 dB per step)
   - `01 01 00 <volume> <other side streaming?>`: **Start**, with G.722 at 16 kHz
   - **Wait for `AudioStatus` = 00 (OK).** Never send audio before that.
5. **Every 20 ms, send one packet** to each aid: 1 sequence byte (shared by both ears, wrapping at 255)
   plus 160 bytes of G.722 (20 ms × 16,000 samples/s ÷ 2 samples per byte). One write = one packet.
   The aid gives back one "credit" per packet it plays. Without credits, that ear's frame is dropped
   instead of queued, so the delay can't grow.

`02` stops. The service sends Stop after 30 s of silence and Start again when sound returns, all on the
same connection. If one aid disconnects, the other is told `03 00`, and `03 01` when it comes back.

## The 20 ms problem

The **connection interval** is how often the Mac and the aid wake up to exchange radio packets. ASHA audio
packets are timed to it, so one packet goes out per interval.

What we found by experiment, and confirmed with a Bluetooth trace: **Oticon Real aids accept Start only when the
interval is exactly 20 ms.** At 10, 15 or 30 ms the aid accepts the write, never answers, and hangs up
2.1 seconds later. It never asks for 20 ms. It just requires it.

macOS picks the interval itself: 15 ms by default, and apps can't choose. Inside the Bluetooth daemon
(`bluetoothd`) the route to 20 ms is:

1. A private CoreBluetooth method, `-[CBCentralManager setDesiredConnectionLatency:forPeripheral:]`, asks for
   "low latency" (level 0). Normally that means a 10–30 ms range, and the Bluetooth chip picks 30.
2. bluetoothd can override that range from the preferences domain `com.apple.MobileBluetooth.debug`
   (dictionary `LE`, keys `LeConnectionLatencyLowMinInterval` / `…MaxInterval`, **in milliseconds**).
   We set both to 20. That's step 2 of `scripts/enable-20ms.sh`.
3. bluetoothd only reads that override when `os_variant_has_internal_diagnostics("com.apple.bluetooth")` is true.
   Apple's open-source `libdarwin` (variant.c) shows that on macOS this is true when
   `/var/db/ConfigurationProfiles/Settings/com.apple.InternalDiagnostics.plist` contains `AppleInternal = true`.
   That folder is protected by SIP, hence the one-time SIP-off step.
4. The answer is computed **once per boot** and stored in the kernel (`kern.osvariant_status`, bits 6–7).
   At a normal boot it's computed before `/var/db` is readable, so it comes out NO. A **userspace reboot**
   (`launchctl reboot userspace`) recomputes it with the file readable, so it comes out YES. The boot helper
   does this once per boot, and never loops: it remembers the kernel boot time it tried on.

Then bluetoothd logs `Override latency minInterval:20` and `new connection parameters interval 20ms-20ms`,
and the aids accept audio.

**Side effect:** with that file, macOS reports "internal diagnostics" to every program that asks. Apple describes
this as enabling extra diagnostic or debugging information. Nothing visibly different was noticed, but you should
know about it.

## Audio path and latency

- The "Hearing Aids" output is a renamed build of BlackHole, a free loopback driver: what apps play into it comes
  out of its hidden input. It runs at 48 kHz stereo.
- The service converts the audio to 16 kHz with `AVAudioConverter`, keeps about 30 ms in a ring buffer to absorb
  timing jitter, then applies a limiter (instant attack) and a hard clamp, then G.722.
- **Latency** is roughly 30 ms of buffer, 20 ms per frame, a few ms of radio, and the aid's own "render delay"
  (89 ms on Oticon Real), so about 150 ms in total. The driver **reports** 130 ms of latency to macOS. Video players
  use that figure to delay the picture to match. It doesn't add any delay itself: the driver's "safety offset" is 0.
  That's the one source change from BlackHole.
- Volume: the driver's volume slider is never applied to the audio. The service reads it and sends it to the aids
  as ASHA volume instead. That way the audio stays at full digital resolution, and the volume keys behave like a
  real headset's.

## Files the service uses

| Path | What |
|---|---|
| `~/.config/asha-mac/known-aids.json` | The paired aids: macOS's device ID, side, pair ID. Written by `asha-probe`. |
| `~/.config/asha-mac/service.json` | The on/off switch. |
| `~/.config/asha-mac/status.json` | Live state for the menu-bar app (rewritten on every change and at least every 2 s). |
| `~/Library/Logs/asha-service.log` | The service log. |
| `~/Library/LaunchAgents/local.asha.{service,menu}.plist` | Start at login. |
| `/Library/LaunchDaemons/local.asha.bootfix.plist` | The boot helper. |
| `/Library/Audio/Plug-Ins/HAL/ASHA Hearing Aids.driver` | The sound output. |

The menu-bar app never touches Bluetooth. It reads `status.json` and sends commands as macOS "distributed
notifications" (`local.asha.command`: on, off, status, quit), the same way `ashactl` does.
