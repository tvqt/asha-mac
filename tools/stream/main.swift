// main.swift (asha-stream) — Phase 3: stream the Mac's system audio to ONE hearing aid.
//
// Captures everything the Mac plays (shared/SystemAudio.swift: Core Audio process tap,
// 16 kHz mono, gain -> limiter -> hard clamp), then streams it with the pipeline proven
// in Phase 2 (shared/AshaStreamer.swift). The Mac's own speakers keep playing too.
//
// Requires the 20 ms setup in docs/FINDINGS.md (internal-diagnostics file, `sudo launchctl reboot
// userspace` after each boot, debug prefs). First run: macOS asks to allow your terminal
// app to record system audio.
//
// SAFETY: start quiet. Defaults: ASHA volume -127 (quietest), gain -20 dB, limiter ceiling
// -20 dBFS (the same cap as the test tone). Raise --volume in small steps (max -64).
//
// USAGE: asha-stream [right|left] [--volume -127] [--gain -20] [--seconds N] [--buffer-ms 30] [--io-frames 256]
//   --buffer-ms  audio kept in reserve before sending (less = lower delay, more risk of gaps)
//   --io-frames  capture chunk size at 48 kHz (256 ≈ 5.3 ms; smaller = lower delay, more CPU)
//   --mute-speakers  silence the Mac's own output while streaming (comes back automatically when stopped)
//        (also the advanced options of asha-tone: --frame-ms, --interval-units, --latency …)

import Foundation

let usage = "Usage: asha-stream [right|left] [--volume -127] [--gain -20] [--seconds N] [--buffer-ms 30] [--io-frames 256] [--mute-speakers] (see top of tools/stream/main.swift)"
var gainDb = -20.0
var bufferMs = 30
var ioFrames: UInt32 = 256
var muteSpeakers = false

let cfg = parseStreamSettings(usage: usage) { option, value in
    switch option {
    case "--gain": gainDb = Double(value()) ?? -20
    case "--buffer-ms": bufferMs = Int(value()) ?? 30
    case "--io-frames": ioFrames = UInt32(value()) ?? 256
    case "--mute-speakers": muteSpeakers = true
    default: return false
    }
    return true
}
if gainDb > 0 { log("NOTE: --gain \(gainDb) clamped to 0 dB (never louder than the original)."); gainDb = 0 }

log("asha-stream: system audio -> \(cfg.side.rawValue.uppercased()) aid, \(cfg.frameMs) ms frames, interval \(cfg.intervalUnits) units, latency level \(cfg.latency.map(String.init) ?? "none").")
let source = SystemAudioSource(gainDb: gainDb, bufferMs: bufferMs, ioFrames: ioFrames, muteLocal: muteSpeakers)
let finder = AidFinder(wanted: cfg.side)
if let ci = cfg.requestCI { finder.setRequestedInterval(units: ci) }
let streamer = AshaStreamer(cfg: cfg, finder: finder, source: source, sourceInfo: [
    "Source: Mac system audio (mono mix), gain \(gainDb) dB, limiter ceiling \(Safety.maxLevelDbfs) dBFS.",
    "Loudest possible ≈ \(Int(100 + Safety.maxLevelDbfs + Safety.volumeDb(cfg.volume))) dB SPL input-equivalent at this volume (peaks only; typical audio is quieter).",
])
runStreamer(streamer, finder: finder, timeoutSeconds: cfg.maxSeconds > 0 ? cfg.maxSeconds + 90 : nil)
