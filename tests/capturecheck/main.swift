// main.swift (capturecheck) — Phase 3 offline test of system-audio capture. NO Bluetooth.
//
// Starts the same SystemAudioSource that asha-stream uses, pulls 20 ms frames on a timer
// for a few seconds (exactly like the streamer), prints the status once a second, then
// writes everything it produced to build/capture-check.wav so it can be checked by ear
// on the Mac's speakers (afplay). Play some audio while it runs.
//
// USAGE: capturecheck [seconds=5] [gainDb=-20] [bufferMs=60]

import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 5
let gainDb = Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? -20
let bufferMs = Int(CommandLine.arguments.dropFirst(3).first ?? "") ?? 60
let source = SystemAudioSource(gainDb: gainDb, bufferMs: bufferMs)
source.debugKeepRaw = true
do { try source.start() } catch { fail(error.localizedDescription) }

var captured: [Int16] = []
var frames = 0
let total = Int(seconds * 50)                         // 50 frames of 20 ms per second
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(20), leeway: .milliseconds(1))
timer.setEventHandler {
    captured += source.next(320)                      // 320 samples = 20 ms at 16 kHz
    frames += 1
    if frames % 50 == 0 { log("t=\(frames / 50) s  " + source.statusLine) }
    if frames >= total {
        timer.cancel()
        source.stop()
        let peak = captured.map { abs(Int($0)) }.max() ?? 0
        log("Captured \(captured.count) samples (\(Double(captured.count) / 16000) s), peak sample \(peak) (hard cap \(Safety.hardPeak)).")
        // Minimal WAV writer: 44-byte header + 16-bit mono PCM at 16 kHz.
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let n = UInt32(captured.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n)
        for s in captured { u16(UInt16(bitPattern: s)) }
        let path = "build/capture-check.wav"
        FileManager.default.createFile(atPath: path, contents: d)
        log("Wrote \(path).")
        // DEBUG: raw 48 kHz float capture + chunk sizes, for comparing with the 16 kHz output.
        _ = source.debugRaw.withUnsafeBufferPointer { FileManager.default.createFile(atPath: "build/capture-raw.f32", contents: Data(buffer: $0)) }
        try? source.debugChunkSizes.map(String.init).joined(separator: "\n").write(toFile: "build/capture-chunks.txt", atomically: true, encoding: .utf8)
        log("Wrote build/capture-raw.f32 (\(source.debugRaw.count) raw samples, \(source.debugChunkSizes.count) chunks).")
        exit(0)
    }
}
timer.resume()
RunLoop.main.run()
