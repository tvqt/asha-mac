// main.swift (asha-tone) — Phase 2: stream a QUIET test tone to ONE hearing aid.
//
// The connect/Start/stream/Stop logic lives in shared/AshaStreamer.swift (proven in
// Phase 2, shared with asha-stream). This file only sets up the tone source.
//
// Defaults = the configuration that WORKS (2026-10-06): private "low latency" level 0,
// which with our bluetoothd settings gives a 20 ms link, plus 20 ms frames. At 15 or 30 ms
// the aid never acknowledges Start. Requires the setup described in docs/FINDINGS.md
// (internal-diagnostics file + `sudo launchctl reboot userspace` after boot + debug prefs).
//
// SAFETY: tone level clamped to <= -20 dBFS per sample (shared/Tone.swift), volume
// clamped to -127…-64, nothing sent before the aid acknowledges Start.
//
// USAGE: asha-tone [right|left|any] [--volume -127] [--level -30] [--seconds 5] [--freq 440]
//   advanced/experiments: [--frame-ms 20] [--interval-units 16] [--latency 0 | --no-latency]
//                         [--no-status] [--no-wait-ack] [--ci N]

import Foundation

let usage = "Usage: asha-tone [right|left|any] [--volume -127] [--level -30] [--seconds 5] [--freq 440] (see top of tools/tone/main.swift)"
var levelDbfs = -30.0
var toneSeconds = 5.0
var freq = 440.0

var cfg = parseStreamSettings(usage: usage) { option, value in
    switch option {
    case "--level": levelDbfs = Double(value()) ?? -30
    case "--freq": freq = Double(value()) ?? 440
    default: return false
    }
    return true
}
// For the tone, --seconds means the tone length (capped), not a streaming time limit.
if cfg.maxSeconds > 0 { toneSeconds = min(cfg.maxSeconds, Safety.maxSeconds); cfg.maxSeconds = 0 }
if levelDbfs > Safety.maxLevelDbfs {
    log("NOTE: level \(levelDbfs) dBFS clamped to \(Safety.maxLevelDbfs)")
    levelDbfs = Safety.maxLevelDbfs
}

let tone = ToneGenerator(frequency: freq, levelDbfs: levelDbfs, seconds: toneSeconds)
let equiv = 100 + levelDbfs + Safety.volumeDb(cfg.volume)
log("asha-tone: \(cfg.side.rawValue.uppercased()) aid, \(cfg.frameMs) ms frames, telling aid interval \(cfg.intervalUnits) units, latency level \(cfg.latency.map(String.init) ?? "none").")

let finder = AidFinder(wanted: cfg.side)
if let ci = cfg.requestCI { finder.setRequestedInterval(units: ci) }
let streamer = AshaStreamer(cfg: cfg, finder: finder, source: tone, sourceInfo: [
    "Source: \(Int(freq)) Hz tone at \(levelDbfs) dBFS for \(toneSeconds) s ≈ \(Int(equiv)) dB SPL input-equivalent.",
])
runStreamer(streamer, finder: finder, timeoutSeconds: 90 + toneSeconds)
