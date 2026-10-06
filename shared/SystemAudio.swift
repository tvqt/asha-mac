// SystemAudio.swift — Phase 3: capture what the Mac is playing, ready for ASHA.
//
// HOW IT WORKS
//   1. Core Audio "process tap" (macOS 14.2+): Apple's API for capturing the audio
//      other apps play. We ask for a MONO mix of ALL processes (one aid = one channel).
//      Needs the "audio recording" permission (Info.plist key NSAudioCaptureUsageDescription).
//   2. A tap can't be read directly. It is added to a private "aggregate device" (a
//      virtual device made of other devices), and we read that device's input. Our
//      block runs on a background queue every few milliseconds with new samples.
//   3. AVAudioConverter resamples from the Mac's rate (usually 48 kHz) to 16 kHz.
//      Going down in rate needs a low-pass filter first, otherwise high frequencies
//      fold back as distortion ("aliasing"). The converter handles that.
//   4. Samples go into a ring buffer. The streaming timer (main thread) takes 20 ms at a
//      time. The two threads share the buffer, so a lock keeps them from clashing.
//   5. SAFETY CHAIN on every sample, in this order: gain -> limiter -> hard clamp.
//      * gain: default -20 dB (typical music peaks near 0 dBFS land near -20 dBFS)
//      * limiter: if a sample would exceed the ceiling (Safety.maxLevelDbfs = -20 dBFS), the
//        gain drops INSTANTLY; it recovers slowly (150 ms). Loud bursts get squashed, not passed on.
//      * hard clamp: whatever happens above, no sample can exceed ±Safety.hardPeak.
//
// LATENCY: we keep about 3 frames (60 ms) buffered. If capture runs ahead (clock drift,
// or audio piled up before streaming began), the excess is dropped. If it runs dry, we send
// silence ("underrun") rather than garbage.

import Foundation
import CoreAudio
import AVFoundation

/// A thread-safe first-in-first-out store of Float samples with a fixed capacity.
final class SampleRing {
    private var buf: [Float]
    private var readPos = 0, count = 0
    private let lock = NSLock()

    init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }

    var available: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Append samples. If the ring is full, the OLDEST samples are overwritten. Returns how many were lost.
    @discardableResult
    func write(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        var lost = 0
        for i in 0..<n {
            buf[(readPos + count) % buf.count] = p[i]
            if count < buf.count { count += 1 } else { readPos = (readPos + 1) % buf.count; lost += 1 }
        }
        return lost
    }

    /// Remove up to n samples into `out` (which starts zero-filled). Returns how many were read.
    func read(into out: inout [Float], _ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let k = min(n, count)
        for i in 0..<k { out[i] = buf[(readPos + i) % buf.count] }
        readPos = (readPos + k) % buf.count
        count -= k
        return k
    }

    /// Throw away the oldest samples so that at most `keep` remain. Returns how many were dropped.
    func trim(keeping keep: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let drop = max(0, count - keep)
        readPos = (readPos + drop) % buf.count
        count -= drop
        return drop
    }
}

/// Instant-attack, slow-release peak limiter. Works on Float samples where 1.0 = full scale.
struct Limiter {
    let ceiling: Float                 // highest allowed absolute sample value
    let releasePerSample: Float        // how fast the gain recovers toward 1
    private(set) var gain: Float = 1

    init(ceilingDbfs: Double, releaseSeconds: Double, sampleRate: Double) {
        ceiling = Float(pow(10, ceilingDbfs / 20))
        releasePerSample = Float(1 - exp(-1 / (releaseSeconds * sampleRate)))
    }

    mutating func process(_ x: Float) -> Float {
        return x * step(peak: abs(x))
    }

    /// Advance the limiter by one sample whose loudest channel has absolute value `peak`,
    /// and return the gain to apply. Stereo uses ONE gain for both channels (a "linked"
    /// limiter), so limiting never shifts the sound towards one ear.
    mutating func step(peak a: Float) -> Float {
        if a * gain > ceiling {
            gain = ceiling / a                          // attack: clamp down immediately
        } else {
            gain += (1 - gain) * releasePerSample       // release: drift back up slowly
        }
        return gain
    }
}

enum SystemAudioError: LocalizedError {
    case coreAudio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case let .coreAudio(what, status):
            // OSStatus codes are often four ASCII letters packed into an integer.
            let fourCC = withUnsafeBytes(of: status.bigEndian) { String(bytes: $0, encoding: .ascii) ?? "" }
            return "\(what) failed (OSStatus \(status) '\(fourCC)'). If this is a permission problem: System Settings > Privacy & Security > Screen & System Audio Recording > allow your terminal app."
        }
    }
}

final class SystemAudioSource: AudioSource {
    let gainDb: Double
    private let outRate = 16_000.0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let captureQueue = DispatchQueue(label: "asha.capture", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    /// 1 = mono mix (one aid), 2 = stereo (left aid, right aid).
    let channels: Int
    private let outFormat: AVAudioFormat
    /// One ring per channel, each holding up to 2 s of 16 kHz audio.
    private let rings: [SampleRing]
    private var ring: SampleRing { rings[0] }
    private var limiter: Limiter
    private var running = false

    // Buffering targets, in samples at 16 kHz (16 samples = 1 ms). A smaller target means
    // less delay but more risk of running dry (a short gap). Set with --buffer-ms.
    private let targetBuffered: Int
    private let maxBuffered: Int
    /// Requested capture chunk size in frames at the device rate (256 at 48 kHz ≈ 5.3 ms).
    private let ioFrames: UInt32
    private var primed = false
    private var refilling = true      // start by building up the cushion

    // Statistics for the status line.
    private var underruns = 0, trimmedSamples = 0, peakOut: Float = 0, sumSquares: Double = 0, statSamples = 0
    private var captureCallbacks = 0

    /// When non-silent audio was last captured (seconds since boot; 0 = never). Written on the
    /// capture queue, read on the main thread; a lock keeps the two from clashing.
    private var lastSoundUptime: Double = 0
    private let soundLock = NSLock()
    /// Seconds since non-silent audio was last captured (huge if never).
    var secondsSinceSound: Double {
        soundLock.lock(); defer { soundLock.unlock() }
        return lastSoundUptime == 0 ? .greatestFiniteMagnitude : ProcessInfo.processInfo.systemUptime - lastSoundUptime
    }

    /// DEBUG: if true, every raw captured sample (before resampling) is also kept here,
    /// together with the size of each chunk, so capturecheck can save and inspect them.
    var debugKeepRaw = false
    private(set) var debugRaw: [Float] = []
    private(set) var debugChunkSizes: [Int] = []

    /// If true, the Mac's own speakers/headphones go silent while we capture
    /// (CATapMutedWhenTapped: muted only while our tap is being read; sound returns
    /// automatically when we stop, even if the program crashes).
    let muteLocal: Bool

    /// DEVICE MODE: if set, read this Core Audio input device (by UID) instead of tapping all
    /// system audio. Used with the "Hearing Aids" output device (driver/): apps play to "Hearing
    /// Aids", and we read the same audio from its hidden "Hearing Aids Monitor" input. No tap, no
    /// aggregate device and no speaker muting needed. Needs the Microphone permission.
    let deviceUID: String?

    init(gainDb: Double, bufferMs: Int = 30, ioFrames: UInt32 = 256, muteLocal: Bool = false, stereo: Bool = false, deviceUID: String? = nil) {
        self.muteLocal = muteLocal
        self.deviceUID = deviceUID
        channels = stereo ? 2 : 1
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: AVAudioChannelCount(stereo ? 2 : 1), interleaved: false)!
        rings = (0..<(stereo ? 2 : 1)).map { _ in SampleRing(capacity: 16_000 * 2) }
        self.gainDb = min(gainDb, 0)     // never amplify above the original (gain <= 0 dB)
        let target = max(10, min(bufferMs, 200))
        targetBuffered = target * 16
        maxBuffered = (target + 60) * 16  // more than ~60 ms over target: trim back
        self.ioFrames = ioFrames
        limiter = Limiter(ceilingDbfs: Safety.maxLevelDbfs, releaseSeconds: 0.15, sampleRate: 16_000)
    }

    var finished: Bool { false }

    var statusLine: String {
        let rms = statSamples > 0 ? sqrt(sumSquares / Double(statSamples)) : 0
        let line = String(format: "capture cb %d, buffered %d ms, underruns %d, trimmed %d ms, out peak %.1f dBFS rms %.1f dBFS, limiter %.1f dB",
                          captureCallbacks, ring.available / 16, underruns, trimmedSamples / 16,
                          20 * log10(max(Double(peakOut), 1e-9)), 20 * log10(max(rms, 1e-9)), 20 * log10(Double(limiter.gain)))
        peakOut = 0; sumSquares = 0; statSamples = 0
        return line
    }

    // MARK: Start: tap -> aggregate device -> IO block

    func start() throws {
        guard !running else { return }
        if let deviceUID { try startDevice(deviceUID); return }

        // 1. The tap: a mono (or stereo) mix of every process, none excluded. Unless
        //    --mute-speakers, the Mac's own speakers/headphones keep playing too.
        let desc = channels == 2 ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                                 : CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "ASHA hearing-aid tap"
        desc.isPrivate = true
        desc.muteBehavior = muteLocal ? .mutedWhenTapped : .unmuted
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw SystemAudioError.coreAudio("Creating the process tap", status) }

        // 2. Its sample format (rate, channels…).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.coreAudio("Reading the tap format", status)
        }
        inFormat = fmt
        log("Capture: tap format \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) channel(s), \(fmt.commonFormat == .pcmFormatFloat32 ? "float32" : "other").")
        guard let conv = AVAudioConverter(from: fmt, to: outFormat) else {
            throw SystemAudioError.coreAudio("Creating the 16 kHz converter", -1)
        }
        converter = conv

        // 3. The private aggregate device: the default output device (for its clock) + our tap.
        let tapUID = desc.uuid.uuidString
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ASHA Capture",
            kAudioAggregateDeviceUIDKey: "asha-capture-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw SystemAudioError.coreAudio("Creating the aggregate device", status) }

        // 3b. Ask for smaller capture chunks (less delay). The device may round or refuse; we log what we got.
        var frames = ioFrames
        var bfAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let setStatus = AudioObjectSetPropertyData(aggregateID, &bfAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        var actual: UInt32 = 0
        var asize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggregateID, &bfAddr, 0, nil, &asize, &actual)
        log("Capture: chunk size requested \(ioFrames), got \(actual) frames (\(String(format: "%.1f", Double(actual) / fmt.sampleRate * 1000)) ms)" + (setStatus == noErr ? "" : " [set failed: \(setStatus)]") + "; buffer target \(targetBuffered / 16) ms.")

        // 4. The IO block: called on our queue with each new chunk of captured audio.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, captureQueue) { [weak self] _, inInput, _, _, _ in
            self?.handleCapture(inInput)
        }
        guard status == noErr else { throw SystemAudioError.coreAudio("Creating the IO block", status) }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw SystemAudioError.coreAudio("Starting capture", status) }
        running = true
        log("Capture: started (system audio, \(channels == 2 ? "stereo" : "mono mix"), gain \(gainDb) dB, limiter ceiling \(Safety.maxLevelDbfs) dBFS)" + (muteLocal ? ", Mac speakers MUTED while streaming." : ")."))
    }

    /// Device mode: read the given input device directly with an IO block.
    private func startDevice(_ uid: String) throws {
        guard let dev = Self.deviceID(forUID: uid) else { throw SystemAudioError.coreAudio("Finding device \(uid)", -1) }
        aggregateID = dev                                   // (stop() stops the IO block on this ID)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { throw SystemAudioError.coreAudio("Reading the device format", status) }
        inFormat = fmt
        guard let conv = AVAudioConverter(from: fmt, to: outFormat) else { throw SystemAudioError.coreAudio("Creating the 16 kHz converter", -1) }
        converter = conv
        var frames = ioFrames
        var bfAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &bfAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, dev, captureQueue) { [weak self] _, inInput, _, _, _ in self?.handleCapture(inInput) }
        guard status == noErr else { throw SystemAudioError.coreAudio("Creating the IO block", status) }
        status = AudioDeviceStart(dev, ioProcID)
        guard status == noErr else { throw SystemAudioError.coreAudio("Starting capture (Microphone permission?)", status) }
        running = true
        log("Capture: reading device \"\(uid)\" (\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch), gain \(gainDb) dB, limiter ceiling \(Safety.maxLevelDbfs) dBFS.")
    }

    /// Core Audio device ID for a device UID (works for hidden devices too), or nil.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = withUnsafeMutablePointer(to: &cfUID) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Runs on captureQueue. Resample this chunk to 16 kHz and append it to the ring.
    private func handleCapture(_ input: UnsafePointer<AudioBufferList>) {
        guard let inFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: input, deallocator: nil),
              inBuf.frameLength > 0 else { return }
        captureCallbacks += 1
        // Activity detection: anything above -60 dBFS counts as "sound is playing".
        if let chans = inBuf.floatChannelData {
            var peak: Float = 0
            for c in 0..<Int(inBuf.format.channelCount) {
                for i in 0..<Int(inBuf.frameLength) { peak = max(peak, abs(chans[c][i])) }
            }
            if peak > 0.001 {
                soundLock.lock(); lastSoundUptime = ProcessInfo.processInfo.systemUptime; soundLock.unlock()
            }
        }
        if debugKeepRaw, let ch = inBuf.floatChannelData?[0] {
            debugRaw.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(inBuf.frameLength)))
            debugChunkSizes.append(Int(inBuf.frameLength))
        }
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * outRate / inFormat.sampleRate) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return }
        var supplied = false
        var error: NSError?
        // The converter "pulls" input through this block. We hand over this one chunk, then
        // say "no data right now", which keeps its filter state for the next chunk.
        converter.convert(to: outBuf, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        if error == nil, outBuf.frameLength > 0, let chans = outBuf.floatChannelData {
            for c in 0..<channels { rings[c].write(chans[c], Int(outBuf.frameLength)) }
        }
    }

    // MARK: Supplying frames to the streamer (main thread)

    /// Mono callers get channel 0 (the whole mix when mono, the left channel when stereo).
    func next(_ count: Int) -> [Int16] { pull(count)[0] }

    /// Left and right frames (identical when capturing mono).
    func nextStereo(_ count: Int) -> (left: [Int16], right: [Int16]) {
        let ch = pull(count)
        return (ch[0], ch[channels - 1])
    }

    /// Take `count` samples per channel from the rings and run the safety chain on them.
    private func pull(_ count: Int) -> [[Int16]] {
        // Use the channel with the LEAST data, so left and right always stay in step.
        let available = rings.map(\.available).min() ?? 0
        // On the first call, throw away whatever piled up during setup, so we start at low latency.
        if !primed {
            primed = true
            trimmedSamples += rings.map { $0.trim(keeping: targetBuffered) }.max() ?? 0
        } else if available > maxBuffered {
            trimmedSamples += rings.map { $0.trim(keeping: targetBuffered) }.max() ?? 0
        }
        // zero-filled: silence if we run dry
        var floats = [[Float]](repeating: [Float](repeating: 0, count: count), count: channels)
        // If we ran dry, wait until a cushion of `targetBuffered` samples has built up again
        // before playing. One short gap sounds much better than many tiny ones (clicks).
        if refilling && (rings.map(\.available).min() ?? 0) >= targetBuffered { refilling = false }
        if !refilling {
            var got = count
            for c in 0..<channels { got = min(got, rings[c].read(into: &floats[c], count)) }
            if got < count {
                underruns += 1
                refilling = true
                // Fade out the partial frame's tail so the gap doesn't start with a click.
                let fade = min(got, 32)
                for c in 0..<channels { for i in 0..<fade { floats[c][got - fade + i] *= Float(fade - i) / Float(fade) } }
            }
        }

        let gain = Float(pow(10, gainDb / 20))
        let hard = Float(Safety.hardPeak) / 32767
        var out = [[Int16]](repeating: [Int16](repeating: 0, count: count), count: channels)
        for i in 0..<count {
            // One limiter gain for all channels, driven by the loudest one ("linked").
            var peak: Float = 0
            for c in 0..<channels { peak = max(peak, abs(floats[c][i] * gain)) }
            let g = limiter.step(peak: peak)
            for c in 0..<channels {
                var y = floats[c][i] * gain * g
                y = min(max(y, -hard), hard)                     // HARD CLAMP: last line of defence
                peakOut = max(peakOut, abs(y))
                sumSquares += Double(y * y); statSamples += 1
                out[c][i] = Int16((y * 32767).rounded())
            }
        }
        return out
    }

    // MARK: Stop

    func stop() {
        guard running else { return }
        running = false
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown && deviceUID == nil { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        log("Capture: stopped.")
    }

    // MARK: Helpers

    /// The UID (a stable text ID) of the Mac's current default output device.
    static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr else { throw SystemAudioError.coreAudio("Finding the default output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw SystemAudioError.coreAudio("Reading the output device UID", status) }
        return uid.takeRetainedValue() as String
    }
}
