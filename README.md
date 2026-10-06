# asha-mac

**Stream your Mac's sound to ASHA hearing aids, on Macs that Apple doesn't support for hearing aids.**

ASHA ("Audio Streaming for Hearing Aids") is Google's Bluetooth Low Energy protocol for streaming
audio to hearing aids. Android phones use it. Macs don't speak ASHA, and Apple's own hearing-aid
streaming ("Made for iPhone", MFi) is switched off on some Macs, including **every base-M1 Mac**
(MacBook Air 2020, MacBook Pro 13" 2020, Mac mini 2020, iMac 2021).

This project adds ASHA to macOS:

- 🦻 **Both hearing aids, in stereo**, with the Mac's **volume keys** controlling the aids' volume
- 🔊 A **"Hearing Aids" sound output** you can pick in System Settings or the menu bar, like headphones
- 🎬 **Lip-sync for video**: the output reports its delay, so video players hold the picture back to match
- 🔋 A **menu-bar app** showing each aid's connection and battery level
- 🔁 A **background service** that reconnects automatically and only streams while sound is playing

> [!WARNING]
> **This is experimental software that sends audio into your ears.** Read [Safety](#safety) first.
> It also needs a **one-time change with System Integrity Protection turned off**, and it relies on a
> hidden macOS setting that Apple could remove in any update. Not a medical device. Not affiliated with
> Apple, Google, Oticon, Demant or Existential Audio.

---

## Will it work for me?

| You need | Notes |
|---|---|
| **ASHA hearing aids** | If your aids stream directly from an Android phone (no extra gadget), they very likely use ASHA. |
| **A Mac on macOS 14.2 or newer** | Tested on a MacBook Air M1 (2020) with macOS 26.5.2. Other Macs and versions are untested. |
| **Admin rights**, and willingness to turn SIP off once | You can turn SIP back on afterwards. |
| **Apple's Command Line Tools** | Free. Install with `xcode-select --install`. No full Xcode needed. |

**Tested hearing aids:** Oticon Real 1 (firmware rel_6.1_29.0). If you try other aids, please
[open an issue](../../issues) saying whether they worked. That is the most useful thing you can contribute.

**Is this the right tool?** If your aids are MFi ("Made for iPhone") **and** your Mac is on
[Apple's supported list](https://support.apple.com/en-us/106341) (M1 Pro/Max/Ultra, and all M2 or newer),
use Apple's built-in support instead: System Settings › Accessibility › Hearing Devices. This project is for
Macs that Apple leaves out, or aids that only speak ASHA.

**Your phone:** hearing aids usually stream from one device at a time. If your phone grabs the aids,
the Mac can't. Turn the phone's Bluetooth off while testing.

---

## Safety

Bugs in audio code can send sound straight into your ear canals. This project was built with that in mind:

- Every sample is **clamped in code** (default ceiling −20 dBFS for tests; never above −6 dBFS), behind a limiter.
- Test tools default to a **quiet tone** at the aids' **lowest** volume, with fade-in and fade-out, and stop after a few seconds.
- Nothing is sent until the aid has **acknowledged** the start command. Ctrl-C (and Ctrl-Z) stop cleanly.
- Silence and garbage are never sent: buffers always start as zeros.

What **you** should do:

1. **Take the aids out of your ears** for your first test runs. Hold them near your ear instead.
2. Start with the defaults. Raise the volume gradually.
3. Know the emergency stop: **`scripts/stop-all.sh`**, or turn your Mac's volume all the way down
   (the aids follow it), or open the battery door.

---

## Setup

Open **Terminal** (Applications › Utilities). Each grey box is one command: copy, paste, press Return.
Commands starting with `sudo` ask for your Mac password (nothing appears as you type; that's normal).

### 1. Download and build

```sh
xcode-select --install
```
(If it says the tools are already installed, that's fine.)

```sh
git clone https://github.com/<you>/asha-mac.git
cd asha-mac
./build.sh
```

It ends with `All built.` Optional self-test (no Bluetooth needed): `build/g722check` should end with `ALL CHECKS PASSED`.

### 2. Turn SIP off (temporarily)

SIP (System Integrity Protection) stops even administrators from changing certain system folders.
Step 3 needs to create **one file** in one of them. You turn SIP back on in step 9.

On Apple silicon:
1. Shut down the Mac. Press and **hold** the power button until "Loading startup options" appears.
2. Click **Options**, then Continue. Sign in if asked.
3. From the menu bar choose **Utilities › Terminal**, then type:
   ```sh
   csrutil disable
   ```
   Confirm, then choose  › Restart.

(On an Intel Mac, hold ⌘R while starting up to reach Recovery instead.)

### 3. Enable the 20 ms Bluetooth setting

From the `asha-mac` folder:

```sh
sudo scripts/enable-20ms.sh
```

It explains what it changes as it goes, then offers a **"userspace reboot"**: all apps close and you
return to the login screen in about 30 seconds. Answer `y`. Why this is needed is in
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md#the-20-ms-problem).

Check that it worked:

```sh
cd asha-mac
scripts/check.sh
```

The lines about internal diagnostics, the 20 ms setting and the boot helper should say **OK**.

### 4. Pair each hearing aid with the Mac

**Turn your phone's Bluetooth off.** Restart both aids (open and close the battery door, or put them
in and out of the charger). Then, one at a time:

```sh
build/asha-probe left
```
```sh
build/asha-probe right
```

macOS may ask to allow Bluetooth for Terminal (click **Allow**) and show a pairing pop-up (click **Pair**
or **Connect**). Look for `RESULT: ASHA service (FDF0) IS present` and `Remembered: … is the LEFT aid` (or RIGHT).
The aids are remembered in `~/.config/asha-mac/known-aids.json`.

### 5. First sound test: aids OUT of your ears

Hold the aids next to your ear, **not in it**.

```sh
build/asha-binaural
```

You should hear a quiet beep: a lower one in the left aid and a higher one in the right. It's very quiet on
purpose, and may be inaudible outside the ear. To make it a bit louder:

```sh
build/asha-binaural --level -20 --volume -80
```

If the log says `AudioStatus 00 (OK)` and `STREAMING`, the hard part works.

### 6. Install the "Hearing Aids" sound output

```sh
sudo scripts/install-driver.sh
```

Sound drops out for about 2 seconds while Core Audio restarts. "Hearing Aids" then appears in
System Settings › Sound › Output.

### 7. Install the background service and menu-bar app

```sh
scripts/install.sh
```

An ear icon appears in the menu bar. macOS asks `asha-service` for **Bluetooth** and **microphone**
permission. Click **Allow** for both. ("Microphone" is how macOS labels reading the Hearing Aids output's
audio. Nothing is recorded or saved.)

### 8. Use it

Click the ear icon › **Use "Hearing Aids" as sound output**, or choose "Hearing Aids" in System Settings › Sound.
Play something. Start with the Mac's volume low: **the volume keys now set the aids' streaming volume.**

### 9. Turn SIP back on

Same as step 2, but type `csrutil enable`. Everything keeps working: the file from step 3 stays, and the
boot helper does its userspace reboot automatically after each restart. That adds a short delay to start-up.

---

## Everyday use

| | |
|---|---|
| **Menu-bar ear icon** | Solid ear = streaming; outline = connected; ear with ⚠ = service not running or no aid connected. Shows each aid's state, battery and volume. |
| **Volume keys** | Change the aids' streaming volume while "Hearing Aids" is the output. Mute = silence. |
| **Stream to hearing aids** (menu) | Pauses or resumes streaming without disconnecting. |
| **Command line** | `~/.local/bin/ashactl status` · `on` · `off` · `quit` |
| **Log** | `~/Library/Logs/asha-service.log` (or menu › Open log) |

The service connects to both aids when they're nearby, starts streaming when sound plays, and stops after
30 seconds of silence to save the aids' batteries.

**Without the driver:** the service can also capture *all* Mac audio directly (a Core Audio "process tap").
It then mutes the Mac's speakers while streaming. The driver is the nicer option: it behaves like any other
output, and it gives you lip-sync.

### The command-line tools

All in `build/`. Run one with `--help` to list its options; each tool's `main.swift` explains them in detail.

| Tool | What it does |
|---|---|
| `asha-probe left\|right\|scan` | Connect to and describe one aid; pairs and remembers it. Sends no audio. |
| `asha-tone left\|right` | Quiet test tone to one aid. |
| `asha-binaural` | Test tone to both aids (`--source system` streams the Mac's audio instead). |
| `asha-stream left\|right` | Mac audio to one aid. |
| `asha-service` | What the background service runs. |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No AudioStatus reply to Start` and the aid disconnects after ~2 s | The 20 ms setting isn't active. Run `scripts/check.sh`; if "internal diagnostics" says NO, run `sudo launchctl reboot userspace`. |
| Stuck at `Opening L2CAP` or "busy with your phone" | Your phone has the aids. Turn the phone's Bluetooth off and restart the aids (battery door). |
| `asha-probe` finds nothing | Restart the aids so they advertise again, and keep them close to the Mac. |
| Connected but silent | Is "Hearing Aids" the sound output? Is the Mac's volume above zero? Did `asha-service` get microphone permission (System Settings › Privacy & Security › Microphone)? |
| Speakers silent after a tool crashed or was killed | `scripts/stop-all.sh` |
| Very quiet | Volume keys up. The aids' own program/volume also applies. Outside the ear everything sounds much quieter than inside. |
| Everything stopped after a macOS update | Apple may have changed the hidden setting. Run `scripts/check.sh` and please open an issue. |

Want to look deeper? `scripts/capture-hci.sh` records a full Bluetooth trace with Apple's PacketLogger.
**Traces contain your aids' pairing keys: never post them publicly.**

---

## Uninstall

```sh
scripts/uninstall.sh
sudo scripts/uninstall-driver.sh
sudo scripts/disable-20ms.sh
```

`disable-20ms.sh` explains how to remove the last file, which needs SIP off once more. On its own, that file
does nothing after a normal restart once the boot helper is gone. To forget the paired aids, delete
`~/.config/asha-mac`, and remove them in System Settings › Bluetooth.

---

## How it works (short version)

1. **Bluetooth.** The Mac connects to each aid with CoreBluetooth, opens an L2CAP channel (a data pipe), and
   follows the ASHA protocol: set the volume, send "start", wait for the aid's OK, then send one audio packet
   every 20 ms.
2. **The 20 ms problem.** Oticon Real aids only accept audio when the Bluetooth link runs at exactly a
   **20 ms connection interval**. macOS never chooses 20 ms, and no public API can change that. macOS does have
   a hidden 20 ms override, but it only reads it on Macs in "internal diagnostics" mode. Step 3 switches that
   mode on, using one file plus a userspace reboot.
3. **Audio.** The "Hearing Aids" output (a renamed build of the open-source BlackHole driver) receives what
   apps play. The service reads it at 48 kHz, converts it to 16 kHz, passes it through a limiter, compresses it
   with **G.722** (the codec ASHA uses; this is Android's own encoder), and sends left and right to the
   matching aid.

The full story, with what was tried and failed: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) and
[docs/FINDINGS.md](docs/FINDINGS.md).

---

## Repository layout

```
build.sh            builds everything into build/
scripts/            setup, install, uninstall, check, emergency stop, trace capture
shared/             the Swift code all tools share (protocol, connection, audio, safety limits)
tools/              command-line tools: probe, tone, stream, binaural
service/            the background service (asha-service) and its remote control (ashactl)
menu/               the menu-bar app
driver/             the "Hearing Aids" sound output (modified BlackHole)
g722/               the G.722 audio codec (from Android, public domain)
tests/              offline self-tests (no Bluetooth)
config/             the hidden bluetoothd setting, as a file
docs/               how it works, and research findings
```

The code is heavily commented for readers new to Swift, Bluetooth and audio.

## Contributing

The most valuable contributions are **reports from other hearing aids and Macs**. Please include your aid
brand, model and firmware (`asha-probe` prints them), your Mac model and macOS version, and whether
`asha-binaural` played. Remove Bluetooth addresses from anything you paste.

## Credits and licence

- Protocol: [Google's ASHA specification](https://source.android.com/docs/core/connect/bluetooth/asha), checked
  against Android's implementation and [asha_pipewire_sink](https://github.com/thewierdnut/asha_pipewire_sink) (Linux).
- G.722 codec: SpanDSP by Steve Underwood, as shipped in the Android Open Source Project; public domain. See `g722/README.md`.
- Sound output: [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio Inc., GPL-3.0.
  This is a **modified** build, renamed as BlackHole's licence requires. Please don't report its bugs to the BlackHole project.
- Written with the help of [Claude Code](https://claude.com/claude-code).

Licensed under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)). The BlackHole driver code is GPL-3.0.
The G.722 code is public domain.
