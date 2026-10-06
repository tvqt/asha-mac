// main.swift (g722check) — offline self-test of the tone generator + G.722 encoder.
//
// Uses NO Bluetooth. It checks, before anything goes near a hearing aid:
//   1. The safety clamp: even when asked for a full-scale tone, no sample
//      exceeds Safety.hardPeak (-20 dBFS).
//   2. Every 15 ms and 20 ms frame encodes to exactly the size ASHA needs
//      (120 / 160 bytes).
//   3. Round trip: encode, then decode with the matching decoder. The result
//      should be the same tone (high signal-to-noise ratio, SNR) at the same level.
//   4. It writes build/tone-original.wav and build/tone-decoded.wav, so you can
//      listen on the Mac's speakers (afplay) and hear that the codec output is clean.
//
// SNR = signal-to-noise ratio: how much bigger the wanted signal is than the
// error, in dB. 20 dB = error is 1/10 of the signal; 30 dB+ sounds clean.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    log((ok ? "PASS  " : "FAIL  ") + what)
    if !ok { failures += 1 }
}

/// Peak absolute sample value.
func peak(_ s: [Int16]) -> Int { s.map { abs(Int($0)) }.max() ?? 0 }

/// RMS = root-mean-square, the average "power" of a signal, in dBFS.
func rmsDbfs(_ s: [Int16]) -> Double {
    let meanSquare = s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(s.count, 1))
    return 20 * log10(max(sqrt(meanSquare), 1e-9) / 32767.0)
}

/// Write a mono 16 kHz 16-bit WAV file. WAV = a 44-byte header followed by the raw samples.
func writeWav(_ samples: [Int16], to path: String) {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let dataBytes = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1)          // PCM format
    u16(1); u32(16000); u32(32000); u16(2); u16(16)                    // mono, 16 kHz, bytes/s, block, bits
    d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
    for s in samples { u16(UInt16(bitPattern: s)) }
    FileManager.default.createFile(atPath: path, contents: d)
    log("      wrote \(path)")
}

// --- 1. Safety clamp ---
log("Test 1: safety clamp")
let loudRequest = ToneGenerator(frequency: 1000, levelDbfs: 0, seconds: 1)   // asks for FULL scale
let loud = loudRequest.next(16000)
check(peak(loud) <= Int(Safety.hardPeak),
      "full-scale request clamped: peak \(peak(loud)) <= \(Safety.hardPeak) (-20 dBFS)")

// --- 2 & 3. Frame sizes + round trip, for both frame lengths ---
for frameMs in [15, 20] {
    log("Test 2/3: \(frameMs) ms frames")
    let n = samplesPerFrame(frameMs: frameMs)
    let want = g722BytesPerFrame(frameMs: frameMs)
    let tone = ToneGenerator(frequency: 440, levelDbfs: -30, seconds: 2)   // the Phase 2 default
    let enc = G722Encoder(), dec = G722Decoder()
    var original: [Int16] = [], decoded: [Int16] = []
    var sizesOK = true
    while !tone.finished {
        let pcm = tone.next(n)
        let bytes = enc.encode(pcm)
        if bytes.count != want { sizesOK = false }
        original += pcm
        decoded += dec.decode(bytes)
    }
    check(sizesOK, "every frame is \(want) bytes (\(original.count / n) frames)")
    check(decoded.count == original.count, "decoded sample count \(decoded.count) == original \(original.count)")

    // The codec delays the audio by a few samples (its filters need history),
    // so find the delay that lines the two signals up best before comparing.
    // Skip the first and last 0.2 s (fades).
    let a = 3200, b = original.count - 3200
    var best = (lag: 0, snr: -999.0)
    for lag in 0...64 {
        var sig = 0.0, err = 0.0
        for i in a..<b {
            let o = Double(original[i]), r = Double(decoded[i + lag])
            sig += o * o; err += (o - r) * (o - r)
        }
        let snr = 10 * log10(sig / max(err, 1e-9))
        if snr > best.snr { best = (lag, snr) }
    }
    log("      codec delay \(best.lag) samples, SNR \(String(format: "%.1f", best.snr)) dB")
    check(best.snr > 25, "round-trip SNR > 25 dB (tone survives encoding)")
    let lvlO = rmsDbfs(Array(original[a..<b])), lvlD = rmsDbfs(Array(decoded[a..<b]))
    check(abs(lvlO - lvlD) < 1.0, String(format: "level preserved: original %.1f dBFS, decoded %.1f dBFS", lvlO, lvlD))
    check(peak(decoded) <= Int(Double(Safety.hardPeak) * 1.1), "decoded peak \(peak(decoded)) stays near the clamp")
    if frameMs == 15 {
        writeWav(original, to: "build/tone-original.wav")
        writeWav(decoded, to: "build/tone-decoded.wav")
    }
}

// --- Silence check: silence must decode back to (near) silence ---
// (The encoded BYTES of silence aren't a constant pattern: G.722's adaptive
// predictor keeps adjusting. What matters is what the aid hears after decoding.)
log("Test 4: silence")
let silenceEnc = G722Encoder(), silenceDec = G722Decoder()
var silenceOut: [Int16] = []
for _ in 0..<20 { silenceOut += silenceDec.decode(silenceEnc.encode([Int16](repeating: 0, count: 240))) }
check(peak(silenceOut) < 50, "silence decodes to near-silence (peak \(peak(silenceOut)) of 32767)")

// --- Limiter: a FULL-SCALE input (0 dBFS, 10x louder than the cap) must come out at or below -20 dBFS ---
log("Test 5: limiter on full-scale input")
var lim = Limiter(ceilingDbfs: Safety.maxLevelDbfs, releaseSeconds: 0.15, sampleRate: 16000)
var limPeak: Float = 0
for i in 0..<16000 {
    let x = Float(sin(2 * Double.pi * 1000 * Double(i) / 16000))   // amplitude 1.0 = 0 dBFS
    limPeak = max(limPeak, abs(lim.process(x)))
}
let cap = Float(pow(10, Safety.maxLevelDbfs / 20))
check(limPeak <= cap * 1.0001, String(format: "limiter output peak %.4f <= ceiling %.4f (%.1f dBFS)", limPeak, cap, 20 * log10(Double(limPeak))))
// And a sudden burst after silence (worst case for a limiter): first sample must already be limited.
var lim2 = Limiter(ceilingDbfs: Safety.maxLevelDbfs, releaseSeconds: 0.15, sampleRate: 16000)
for _ in 0..<1000 { _ = lim2.process(0) }
check(abs(lim2.process(1.0)) <= cap * 1.0001, "a sudden full-scale sample after silence is limited immediately")

log(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
