// main.swift (asha-binaural) — Phase 4: stream to BOTH hearing aids at once.
//
// Default source: a test tone with a DIFFERENT pitch per ear (left 440 Hz, right 660 Hz, the
// higher one on the right), so you can check the sides aren't swapped.
// `--source system` streams the Mac's system audio in stereo (left channel -> left aid).
//
// Requires: both aids known (asha-probe left / right once) and the 20 ms setup in docs/FINDINGS.md.
// SAFETY: aids OUT of your ears for the first run. Same caps as the other tools.
//
// USAGE: asha-binaural [--source tone|system] [--volume -127] [--level -30] [--gain -20]
//                      [--seconds N] [--buffer-ms 30] [--mute-speakers] [--ceiling dBFS]
//   With --source system the defaults are: Mac volume keys control the aids (top of the slider =
//   --max-volume, default 0 = the aid's full streaming level), gain 0 dB, ceiling -6 dBFS, Mac speakers muted.
//   (Full volume is wanted for quiet speech, e.g. someone softly across the room on a call; music needs
//   less, which is what the slider is for.)
//   Opt out with --no-keys (then --volume is used) and --keep-speakers.

import Foundation

let usage = "Usage: asha-binaural [--source tone|system] [--volume -127] [--level -30] [--gain -20] [--seconds N] [--buffer-ms 30] [--mute-speakers]"
var sourceKind = "tone", levelDbfs = -30.0, gainDb: Double? = nil, bufferMs = 30, muteSpeakers = false
var useKeys = true, keepSpeakers = false, maxVolume: Int8 = 0

var cfg = parseStreamSettings(usage: usage) { option, value in
    switch option {
    case "--source": sourceKind = value()
    case "--level": levelDbfs = Double(value()) ?? -30
    case "--gain": gainDb = Double(value()) ?? -20
    case "--no-keys": useKeys = false
    case "--keep-speakers": keepSpeakers = true
    case "--max-volume": maxVolume = Int8(value()) ?? 0
    case "--buffer-ms": bufferMs = Int(value()) ?? 30
    case "--mute-speakers": muteSpeakers = true
    default: return false
    }
    return true
}
levelDbfs = min(levelDbfs, Safety.maxLevelDbfs)

let source: AudioSource
var info: [String]
switch sourceKind {
case "tone":
    let secs = cfg.maxSeconds > 0 ? min(cfg.maxSeconds, Safety.maxSeconds) : 5
    cfg.maxSeconds = 0
    source = StereoTone(leftHz: 440, rightHz: 660, levelDbfs: levelDbfs, seconds: secs)
    info = ["Source: test tone, LEFT 440 Hz (lower) / RIGHT 660 Hz (higher), \(levelDbfs) dBFS, \(secs) s."]
case "system":
    // Everyday defaults: the volume keys do the attenuation, so the audio itself runs at full gain
    // up to a -6 dBFS ceiling (unless the user chose otherwise).
    if useKeys && !CommandLine.arguments.contains("--ceiling") { Safety.setCeiling(-6) }
    let g = min(gainDb ?? (useKeys ? 0 : -20), 0)
    let mute = muteSpeakers || (useKeys && !keepSpeakers)
    source = SystemAudioSource(gainDb: g, bufferMs: bufferMs, muteLocal: mute, stereo: true)
    info = ["Source: Mac system audio in STEREO, gain \(g) dB, linked limiter ceiling \(Safety.maxLevelDbfs) dBFS" + (mute ? ", speakers muted." : ".")]
default:
    fail("--source must be tone or system", code: 64)
}
log("asha-binaural: both aids, \(cfg.frameMs) ms frames, latency level \(cfg.latency.map(String.init) ?? "none").")
let streamer = BinauralStreamer(cfg: cfg, source: source, sourceInfo: info)
if sourceKind == "system" && useKeys {
    let keys = VolumeKeys(maxVolume: maxVolume)
    keys.start()
    streamer.volumeKeys = keys
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
var ctrlC = 0
sigint.setEventHandler {
    ctrlC += 1
    if ctrlC > 1 { source.stop(); log("Second Ctrl-C: exiting now."); exit(130) }
    log("Ctrl-C: stopping cleanly (press again to force quit)…")
    streamer.stopAll("Ctrl-C")
}
sigint.resume()
// Ctrl-Z (SIGTSTP) would normally PAUSE the program, leaving the capture active and the speakers
// muted (it happened on 2026-10-06). Treat it like Ctrl-C instead: stop cleanly.
signal(SIGTSTP, SIG_IGN)
let sigtstp = DispatchSource.makeSignalSource(signal: SIGTSTP, queue: .main)
sigtstp.setEventHandler { log("Ctrl-Z: stopping cleanly (this program can't be paused)…"); streamer.stopAll("Ctrl-Z") }
sigtstp.resume()
streamer.start()
RunLoop.main.run()
