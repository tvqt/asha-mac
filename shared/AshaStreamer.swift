// AshaStreamer.swift — connects to one aid and streams audio from any AudioSource.
//
// This is the logic proven in Phase 2 (asha-tone), moved here unchanged in behaviour
// so the tone tool and the real-audio tool share ONE tested pipeline.
//
// THE SEQUENCE (copied from Android's hearing_aid.cc, checked against the spec):
//   1. Find and connect to the aid (AidFinder). Ask macOS for the "low latency"
//      connection level. With our bluetoothd settings that gives a 20 ms link,
//      which this aid REQUIRES (at 15/30 ms it never acknowledges Start).
//   2. Read ReadOnlyProperties (side, G.722 support) and the PSM; subscribe to AudioStatus.
//   3. Open the L2CAP audio channel on the PSM.
//   4. Write Volume, then "connection parameters updated" + interval, then Start.
//      WAIT until the aid notifies AudioStatus = 0 (OK) before sending any audio.
//   5. Every frame period, send one packet: [sequence byte] + G.722 audio.
//   6. Write Stop, close, disconnect. Ctrl-C does the same (twice = force quit).
//
// SAFETY: volume is clamped to Safety.minVolume…maxVolume. Each source clamps its own
// samples to Safety.hardPeak. Nothing is streamed before the aid acknowledges Start.
// Any partial write stops the stream rather than risk misframed (noisy) audio.

import Foundation
import CoreBluetooth

// MARK: - A source of audio samples

/// Anything that can supply 16 kHz mono 16-bit samples, one frame at a time.
/// A "protocol" in Swift is like a Java interface: a list of things a type promises to do.
protocol AudioSource: AnyObject {
    /// Called when streaming is about to begin (e.g. start capturing). May fail.
    func start() throws
    /// Called when streaming ends. Must be safe to call more than once.
    func stop()
    /// The next `count` samples. Must always return exactly `count` (pad with silence).
    func next(_ count: Int) -> [Int16]
    /// True when the source has nothing more to play (a tone that ended).
    var finished: Bool { get }
    /// Short text for the once-a-second status line.
    var statusLine: String { get }
    /// Left and right frames. (Has a default below: mono sources send the same to both ears.)
    func nextStereo(_ count: Int) -> (left: [Int16], right: [Int16])
}

extension AudioSource {
    /// Default for mono sources: the same audio to both ears. Stereo sources override this.
    func nextStereo(_ count: Int) -> (left: [Int16], right: [Int16]) {
        let m = next(count)
        return (m, m)
    }
}

/// The test tone is a source too. Its methods already match. Only start/stop/statusLine are new.
extension ToneGenerator: AudioSource {
    func start() throws {}
    func stop() {}
    var statusLine: String { "" }
}

// MARK: - Settings shared by every streaming tool

struct StreamSettings {
    var side: Side = .right
    var frameMs = 20                 // audio per packet; must match the link interval (spec)
    var intervalUnits: UInt8 = 16    // interval we tell the aid, 1.25 ms units (16 = 20 ms)
    var volume: Int8 = Safety.minVolume
    var latency: Int? = 0            // private setDesiredConnectionLatency level; 0 -> 20 ms with our prefs
    var requestCI: Int?              // EXPERIMENT (ineffective): private connect options
    var sendStatus = true            // send "03 02 <interval>" before Start, like Android
    var waitForAck = true            // wait for AudioStatus 0 before streaming (spec)
    var maxSeconds = 0.0             // stop after this long; 0 = until Ctrl-C (or the source finishes)
}

/// Parse the options every streaming tool understands. Tool-specific options are
/// passed to `extra(option, nextValue)`, which returns true if it handled them.
func parseStreamSettings(usage: String, extra: (String, () -> String) -> Bool = { _, _ in false }) -> StreamSettings {
    var s = StreamSettings()
    var args = Array(CommandLine.arguments.dropFirst())
    func value() -> String {
        guard !args.isEmpty else { fail("missing value after an option. \(usage)", code: 64) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "left", "right", "any": s.side = Side(rawValue: a)!
        case "--frame-ms": s.frameMs = Int(value()) ?? -1
        case "--interval-units": s.intervalUnits = UInt8(value()) ?? 0
        case "--volume": s.volume = Int8(value()) ?? Safety.minVolume
        case "--latency": s.latency = Int(value())
        case "--no-latency": s.latency = nil
        case "--ci": s.requestCI = Int(value())
        case "--no-status": s.sendStatus = false
        case "--no-wait-ack": s.waitForAck = false
        case "--seconds": s.maxSeconds = Double(value()) ?? 0
        case "--ceiling":
            // Must be applied BEFORE any audio source is created (they read Safety.maxLevelDbfs).
            let want = Double(value()) ?? -20
            Safety.setCeiling(want)
            if Safety.maxLevelDbfs != want { log("NOTE: --ceiling \(want) clamped to \(Safety.maxLevelDbfs) dBFS (allowed -40…\(Safety.absoluteMaxDbfs)).") }
        case "-h", "--help": print(usage); exit(0)
        default:
            if !extra(a, value) { fail("unknown argument '\(a)'. \(usage)", code: 64) }
        }
    }
    // 30 ms frames = 241-byte packets, the largest that fits the aid's 248-byte L2CAP MTU.
    guard [10, 15, 20, 30].contains(s.frameMs) else { fail("--frame-ms must be 10, 15, 20 or 30", code: 64) }
    guard (6...24).contains(s.intervalUnits) else { fail("--interval-units must be 6…24 (7.5…30 ms)", code: 64) }
    let v = min(max(s.volume, Safety.minVolume), Safety.maxVolume)
    if v != s.volume { log("NOTE: volume \(s.volume) clamped to \(v) (allowed \(Safety.minVolume)…\(Safety.maxVolume))") }
    s.volume = v
    return s
}

// MARK: - The streamer

final class AshaStreamer: NSObject, CBPeripheralDelegate, StreamDelegate {
    let cfg: StreamSettings
    let finder: AidFinder
    let source: AudioSource
    /// Lines describing the source and its loudness, shown before streaming starts.
    let sourceInfo: [String]

    // GATT handles, filled in as they're discovered.
    var aid: CBPeripheral?
    var controlPoint: CBCharacteristic?
    var volumeChar: CBCharacteristic?
    var props: AshaProperties?
    var psm: UInt16?
    var statusSubscribed = false

    // Audio channel.
    var channel: CBL2CAPChannel?
    var output: OutputStream? { channel?.outputStream }
    var channelReady = false
    var channelRequested = false

    // Where we are in the sequence.
    enum Phase { case setup, countdown, awaitingStartAck, streaming, stopping, done }
    var phase = Phase.setup
    var startWriteConfirmed = false
    var startAcked = false

    // Streaming state.
    let encoder = G722Encoder()
    var seq: UInt8 = 0                  // sequence byte: wraps 255 -> 0 by itself (&+=)
    var timer: DispatchSourceTimer?
    var streamStart: UInt64 = 0         // when streaming began, in nanoseconds
    var slotsDone = 0                   // frame periods handled (sent or dropped)
    var tailFrames = 0                  // silent frames sent after the source finishes

    // Statistics, printed every second and at the end.
    var sent = 0, droppedNoSpace = 0, skippedLate = 0
    var maxLatenessMs = 0.0

    init(cfg: StreamSettings, finder: AidFinder, source: AudioSource, sourceInfo: [String]) {
        self.cfg = cfg
        self.finder = finder
        self.source = source
        self.sourceInfo = sourceInfo
        super.init()
        finder.onConnected = { [unowned self] p in
            aid = p; controlPoint = nil; volumeChar = nil; props = nil; psm = nil; statusSubscribed = false
            p.delegate = self
            // Ask for the "low latency" level first; the update takes ~0.2 s, long before Start.
            if let lvl = cfg.latency { finder.setDesiredConnectionLatency(lvl, for: p) }
            p.discoverServices([ashaServiceUUID])
        }
        finder.onDisconnected = { [unowned self] _, error in
            if phase == .done || phase == .stopping { log("Disconnected cleanly."); return }
            source.stop()
            fail("aid disconnected unexpectedly during phase \(phase): \(error?.localizedDescription ?? "no reason given")", code: 4)
        }
    }

    // MARK: GATT setup

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = p.services?.first(where: { $0.uuid == ashaServiceUUID }) else {
            fail("no ASHA service on this aid (\(error?.localizedDescription ?? "not found"))")
        }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case readOnlyPropsUUID, psmUUID: p.readValue(for: c)
            case audioStatusUUID: p.setNotifyValue(true, for: c)
            case audioControlUUID: controlPoint = c
            case volumeUUID: volumeChar = c
            default: break
            }
        }
        guard controlPoint != nil, volumeChar != nil else { fail("ASHA AudioControlPoint/Volume characteristic missing") }
        log("ASHA characteristics found. Reading properties… (accept any pairing pop-up)")
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            log("Subscribe to AudioStatus failed (\(error.localizedDescription)). Retrying in 3 s.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { p.setNotifyValue(true, for: c) }
            return
        }
        statusSubscribed = c.isNotifying
        log("Subscribed to AudioStatus notifications.")
        maybeOpenChannel()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            log("Read of \(name(c.uuid)) failed (\(error.localizedDescription)). Retrying in 5 s (accept any pairing pop-up).")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { p.readValue(for: c) }
            return
        }
        guard let v = c.value else { return }
        switch c.uuid {
        case readOnlyPropsUUID:
            guard let pr = AshaProperties(v) else { fail("ReadOnlyProperties too short: \(hex(v))") }
            pr.describe().forEach { log($0) }
            guard finder.checkSide(pr, of: p) else { return }
            guard pr.supportsStreaming, pr.supportsG722_16k else { fail("this aid doesn't offer G.722 streaming") }
            props = pr
        case psmUUID:
            guard v.count == 2 else { fail("PSM has unexpected length \(v.count)") }
            psm = le16(v, 0)
            log("Audio PSM = \(psm!)")
        case audioStatusUUID:
            handleAudioStatus(v)
            return
        default: break
        }
        maybeOpenChannel()
    }

    // MARK: L2CAP

    func maybeOpenChannel() {
        guard props != nil, let psm, statusSubscribed, !channelRequested, let aid else { return }
        channelRequested = true
        log("Opening L2CAP channel on PSM \(psm)…")
        aid.openL2CAPChannel(CBL2CAPPSM(psm))
        // If the aid refuses the channel ("No Resources Available": it is already streaming to
        // another device, e.g. the phone), macOS does NOT report the failure to apps: it just waits.
        // Seen in the HCI trace on 2026-10-06. So give up after 10 s with a useful hint.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.channel == nil, self.phase == .setup else { return }
            log("The aid did not open the audio channel within 10 s. Most likely it's busy with another device:")
            log("  turn off Bluetooth on your phone (or restart the aid via the battery door), then try again.")
            self.finishNow()
        }
    }

    func peripheral(_ p: CBPeripheral, didOpen ch: CBL2CAPChannel?, error: Error?) {
        guard error == nil, let ch else { fail("L2CAP open failed: \(error.map { "\($0)" } ?? "no channel")") }
        channel = ch
        for s in [ch.inputStream as Stream?, ch.outputStream as Stream?].compactMap({ $0 }) {
            s.delegate = self
            s.schedule(in: .main, forMode: .default)
            s.open()
        }
        log("L2CAP channel open.")
    }

    func stream(_ s: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted where s === output:
            if !channelReady { channelReady = true; beginCountdown() }
        case .hasBytesAvailable:
            // The aid isn't expected to send anything back. Read and log it, so it can't pile up.
            if let input = s as? InputStream {
                var buf = [UInt8](repeating: 0, count: 512)
                let n = input.read(&buf, maxLength: buf.count)
                if n > 0 { log("  (aid sent \(n) bytes on the audio channel: \(hex(Array(buf[0..<n].prefix(16)))))") }
            }
        case .errorOccurred:
            log("L2CAP stream ERROR: \(s.streamError?.localizedDescription ?? "?")")
            stopStreaming(reason: "stream error")
        case .endEncountered:
            log("L2CAP stream closed by the aid.")
            stopStreaming(reason: "channel closed by aid")
        default: break
        }
    }

    // MARK: Volume, connection-update notice, Start

    func beginCountdown() {
        phase = .countdown
        log("READY. Volume \(cfg.volume) (\(String(format: "%.1f", Safety.volumeDb(cfg.volume))) dB), \(cfg.frameMs) ms frames (\(g722BytesPerFrame(frameMs: cfg.frameMs)) bytes + 1 seq byte).")
        sourceInfo.forEach { log("       " + $0) }
        log("       SAFETY: aids OUT of your ears for the first run of new audio code. Ctrl-C now to abort. Starting in 3 s…")
        // Start the source now (e.g. begin capturing) so audio is buffered by the time Start is acked.
        do { try source.start() } catch {
            log("Audio source failed to start: \(error.localizedDescription)")
            finishNow()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard phase == .countdown, let aid, let controlPoint, let volumeChar else { return }
            write(aid, [UInt8(bitPattern: cfg.volume)], to: volumeChar, .withoutResponse, "Volume")
            if cfg.sendStatus {
                write(aid, AshaCommand.connParamsUpdated(intervalUnits: cfg.intervalUnits), to: controlPoint,
                      .withoutResponse, "Status: conn params updated (interval \(cfg.intervalUnits) = \(Double(cfg.intervalUnits) * 1.25) ms)")
            }
            // Pause so a status reply to the message above can't be mistaken for the reply to Start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                guard phase == .countdown else { return }
                phase = .awaitingStartAck
                write(aid, AshaCommand.start(volume: cfg.volume, otherSideStreaming: false), to: controlPoint,
                      .withResponse, "Start")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                    if phase == .awaitingStartAck {
                        log("No AudioStatus reply to Start within 3 s. (Is the link at 20 ms? See docs/FINDINGS.md.)")
                        stopStreaming(reason: "Start not acknowledged")
                    }
                }
            }
        }
    }

    func write(_ p: CBPeripheral, _ bytes: [UInt8], to c: CBCharacteristic, _ type: CBCharacteristicWriteType, _ what: String) {
        log("-> \(what): \(hex(bytes))")
        p.writeValue(Data(bytes), for: c, type: type)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            log("Write to \(name(c.uuid)) FAILED: \(error.localizedDescription)")
            if phase == .awaitingStartAck { stopStreaming(reason: "Start write rejected") }
            if phase == .stopping { finishNow() }
            return
        }
        switch phase {
        case .awaitingStartAck:
            log("   Start write accepted by the aid. Waiting for AudioStatus…")
            startWriteConfirmed = true
            maybeBeginStreaming()
        case .stopping:
            log("   Stop write accepted.")
            finishNow()
        default: break
        }
    }

    func handleAudioStatus(_ v: Data) {
        guard let raw = v.first else { return }
        log("<- AudioStatus notification: \(hex(v)) (\(describeAudioStatus(raw)))")
        guard phase == .awaitingStartAck else { return }
        if raw == 0 {
            startAcked = true
            maybeBeginStreaming()
        } else {
            stopStreaming(reason: "aid rejected Start")
        }
    }

    // MARK: Streaming

    func maybeBeginStreaming() {
        guard phase == .awaitingStartAck, startWriteConfirmed, startAcked || !cfg.waitForAck else { return }
        if !startAcked { log("   (EXPERIMENT --no-wait-ack: streaming without an AudioStatus OK)") }
        phase = .streaming
        streamStart = DispatchTime.now().uptimeNanoseconds
        log("STREAMING (sequence starts at 0)" + (cfg.maxSeconds > 0 ? " for \(cfg.maxSeconds) s" : ". Ctrl-C to stop") + "…")

        // Fires every frame period on the main thread, at most 1 ms late ("leeway").
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(cfg.frameMs), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()

        func report() {
            guard phase == .streaming else { return }
            let extra = source.statusLine
            log("   sent \(sent), dropped(no space) \(droppedNoSpace), skipped(late) \(skippedLate), max lateness \(String(format: "%.1f", maxLatenessMs)) ms" + (extra.isEmpty ? "" : " | " + extra))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: report)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: report)
    }

    /// Called every frame period. Works out from the clock how many frames should
    /// have gone out by now, so timer jitter doesn't build up into drift.
    func tick() {
        guard phase == .streaming else { return }
        let frameNs = UInt64(cfg.frameMs) * 1_000_000
        let elapsed = DispatchTime.now().uptimeNanoseconds - streamStart
        if cfg.maxSeconds > 0 && Double(elapsed) / 1e9 >= cfg.maxSeconds {
            stopStreaming(reason: "--seconds reached")
            return
        }
        let due = Int(elapsed / frameNs) + 1
        maxLatenessMs = max(maxLatenessMs, Double(elapsed % frameNs) / 1e6)

        // More than 3 frames behind (the Mac was busy)? Skip ahead rather than burst old audio.
        if due - slotsDone > 3 {
            let skip = due - slotsDone - 1
            skippedLate += skip
            _ = source.next(skip * samplesPerFrame(frameMs: cfg.frameMs))   // discard, keeps timelines aligned
            slotsDone += skip
        }
        while slotsDone < due && phase == .streaming {
            sendOneFrame()
            slotsDone += 1
        }
    }

    func sendOneFrame() {
        guard let output else { return }
        // After a finite source ends, send 10 frames of silence, then stop cleanly.
        if source.finished {
            tailFrames += 1
            if tailFrames > 10 { stopStreaming(reason: "source finished"); return }
        }
        let pcm = source.next(samplesPerFrame(frameMs: cfg.frameMs))
        let audio = encoder.encode(pcm)                  // size checked inside
        let packet = [seq] + audio                       // one L2CAP packet (SDU)
        precondition(packet.count == g722BytesPerFrame(frameMs: cfg.frameMs) + 1)

        // No credits from the aid -> the stream reports no space. Like Android, drop the
        // frame and do NOT advance the sequence number.
        guard output.hasSpaceAvailable else {
            droppedNoSpace += 1
            return
        }
        let n = packet.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
        if n != packet.count {
            log("Write of \(packet.count)-byte packet returned \(n). Stopping for safety.")
            stopStreaming(reason: "partial/failed write")
            return
        }
        sent += 1
        seq &+= 1
    }

    // MARK: Stop and clean up

    func stopStreaming(reason: String) {
        guard phase != .stopping && phase != .done else { return }
        let wasActive = (phase == .streaming || phase == .awaitingStartAck)
        phase = .stopping
        timer?.cancel(); timer = nil
        source.stop()
        log("STOPPING (\(reason)). Totals: sent \(sent), dropped(no space) \(droppedNoSpace), skipped(late) \(skippedLate), max lateness \(String(format: "%.1f", maxLatenessMs)) ms")
        if wasActive, let aid, let controlPoint {
            write(aid, AshaCommand.stop(), to: controlPoint, .withResponse, "Stop")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishNow() }
        } else {
            finishNow()
        }
    }

    func finishNow() {
        guard phase != .done else { return }
        phase = .done
        source.stop()
        channel?.outputStream?.close()
        channel?.inputStream?.close()
        channel = nil
        finder.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { log("Done."); exit(0) }
    }
}

// MARK: - Shared program start-up

/// Objects that must live for the whole run (CoreBluetooth only keeps weak references).
var streamerKeepAlive: [AnyObject] = []

/// Wire up Ctrl-C handling and a safety timeout, then run forever.
/// Ctrl-C sends Stop first; a second Ctrl-C exits at once.
func runStreamer(_ streamer: AshaStreamer, finder: AidFinder, timeoutSeconds: Double?) -> Never {
    streamerKeepAlive = [finder, streamer]
    signal(SIGINT, SIG_IGN)                      // replace the default "die immediately"
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var ctrlC = 0
    sigint.setEventHandler {
        ctrlC += 1
        if ctrlC > 1 { streamer.source.stop(); log("Second Ctrl-C: exiting now."); exit(130) }
        log("Ctrl-C: stopping cleanly (press again to force quit)…")
        if streamer.phase == .setup || streamer.phase == .countdown { streamer.finishNow() }
        else { streamer.stopStreaming(reason: "Ctrl-C") }
    }
    sigint.resume()
    streamerKeepAlive.append(sigint as AnyObject)
    // Ctrl-Z would PAUSE the program with the capture still active (speakers stay muted). Stop cleanly instead.
    signal(SIGTSTP, SIG_IGN)
    let sigtstp = DispatchSource.makeSignalSource(signal: SIGTSTP, queue: .main)
    sigtstp.setEventHandler {
        log("Ctrl-Z: stopping cleanly (this program can't be paused)…")
        if streamer.phase == .setup || streamer.phase == .countdown { streamer.finishNow() }
        else { streamer.stopStreaming(reason: "Ctrl-Z") }
    }
    sigtstp.resume()
    streamerKeepAlive.append(sigtstp as AnyObject)
    finder.start()
    if let t = timeoutSeconds {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            log("Overall timeout.")
            streamer.stopStreaming(reason: "overall timeout")
        }
    }
    RunLoop.main.run()
    exit(0)
}
