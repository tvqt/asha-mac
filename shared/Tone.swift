// Tone.swift — the quiet test-tone generator and the audio SAFETY LIMITS.
//
// Audio terms:
//   sample   – one number giving the sound-wave height at one instant. We use
//              16-bit signed integers (-32768…32767), 16,000 per second (16 kHz).
//   dBFS     – "decibels relative to full scale". 0 dBFS is the loudest a
//              16-bit sample can be. -20 dBFS is 1/10 of that amplitude,
//              -40 dBFS is 1/100. Every -6 dB roughly halves the amplitude.
//   fade     – ramping the volume up/down over ~0.1 s. Switching a tone on or
//              off instantly makes a click, a sudden jump in the waveform.
//
// HOW LOUD IS IT IN THE EAR? The ASHA spec says: at stream volume 0, a full-scale
// (0 dBFS) sine "must represent a 100 dB SPL input equivalent". In other words,
// the aid treats it like a 100 dB sound arriving at its microphones, which is
// about as loud as a lawnmower. Volume -127 subtracts 47.6 dB. So:
//     equivalent input level ≈ 100 + levelDbfs + volumeDb
//   defaults: 100 - 30 - 47.6 ≈ 22 dB SPL  (quieter than a whisper, ~30 dB)
//   hard cap: 100 - 20 - 24.0 =  56 dB SPL  (quiet conversation, ~60 dB)
// The aid then applies its own fitted amplification on top, as for any sound.

import Foundation

enum Safety {
    /// The ceiling every sample is held under (limiter + hard clamp). Default -20 dBFS, the level
    /// used for all first tests. Can be raised with --ceiling, but never above `absoluteMaxDbfs`.
    /// (Raised 2026-10-06 after streaming worked: at -20 dBFS and volume <= -64, real audio was
    /// "barely a whisper" in the ear.)
    static var maxLevelDbfs = -20.0
    /// Hard upper bound for --ceiling: -6 dBFS leaves headroom below digital full scale.
    static let absoluteMaxDbfs = -6.0
    /// Peak sample value matching maxLevelDbfs (e.g. -20 dBFS -> 3276, -6 dBFS -> 16422).
    /// EVERY sample is clamped to ±this, even if the maths above it had a bug.
    static var hardPeak: Int16 { Int16(32767.0 * pow(10.0, maxLevelDbfs / 20.0)) }

    /// Set the ceiling once at start-up (from --ceiling). Clamped to -40…absoluteMaxDbfs.
    static func setCeiling(_ dbfs: Double) {
        maxLevelDbfs = min(max(dbfs, -40), absoluteMaxDbfs)
    }

    /// ASHA volume is a signed byte: -128 = mute, -127 = quietest audible (-47.6 dB), 0 = the aid's
    /// normal full streaming level (what Android/iPhone use at maximum). The aid's own fitted
    /// maximum output still applies on top. Default stays at the quietest step.
    static let minVolume: Int8 = -127
    static let maxVolume: Int8 = 0

    /// Longest test tone, in seconds.
    static let maxSeconds = 30.0

    /// ASHA volume step -> dB attenuation. The spec maps -128…0 onto -48…0 dB,
    /// i.e. 48/128 = 0.375 dB per step.
    static func volumeDb(_ v: Int8) -> Double { Double(v) * 48.0 / 128.0 }
}

/// Generates a sine tone with fade-in and fade-out, a fixed number of samples
/// long. After that it produces silence (zeros).
final class ToneGenerator {
    let sampleRate = 16_000.0
    let frequency: Double
    let amplitude: Double       // peak sample value (before fades)
    let totalSamples: Int       // tone length; silence afterwards
    let fadeSamples: Int        // length of each fade
    private var produced = 0    // samples generated so far
    private var phase = 0.0     // position in the sine cycle, in radians

    init(frequency: Double, levelDbfs: Double, seconds: Double, fadeSeconds: Double = 0.1) {
        // Clamp every input to a safe range, whatever the caller asked for.
        self.frequency = min(max(frequency, 100), 4000)
        let level = min(levelDbfs, Safety.maxLevelDbfs)
        amplitude = 32767.0 * pow(10.0, level / 20.0)    // dBFS -> linear amplitude
        totalSamples = Int(min(max(seconds, 0.5), Safety.maxSeconds) * sampleRate)
        fadeSamples = Int(fadeSeconds * sampleRate)
    }

    var finished: Bool { produced >= totalSamples }

    /// The next `count` samples.
    func next(_ count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)   // starts as silence, never garbage
        let step = 2.0 * Double.pi * frequency / sampleRate   // phase advance per sample
        let peak = Double(Safety.hardPeak)
        for i in 0..<count {
            let n = produced + i
            guard n < totalSamples else { break }        // past the end: leave silence
            // Fade gain: ramps 0→1 at the start and 1→0 at the end.
            let fadeIn = min(1.0, Double(n) / Double(fadeSamples))
            let fadeOut = min(1.0, Double(totalSamples - n) / Double(fadeSamples))
            let value = amplitude * min(fadeIn, fadeOut) * sin(phase)
            // THE SAFETY CLAMP: never exceed ±hardPeak, whatever happened above.
            out[i] = Int16(min(max(value, -peak), peak).rounded())
            phase += step
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }   // keep the number small
        }
        produced += count
        return out
    }
}
