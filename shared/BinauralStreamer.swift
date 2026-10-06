// BinauralStreamer.swift — Phase 4: stream to BOTH hearing aids together.
//
// How Android does it (AOSP hearing_aid.cc, checked 2026-10-06), copied here:
//   - Each aid has its own connection and L2CAP audio channel (AidLink).
//   - ONE sequence counter for both: every 20 ms the left and right frames are sent
//     with the SAME sequence byte, so the aids (which talk to each other) can line up.
//   - A separate G.722 encoder per ear (each ear is its own continuous stream).
//   - Start's last byte ("otherstate") = 1 when the other aid is connected too.
//   - When one aid drops out, the other is told: Status 03 00 ("other side disconnected").
//   - If one aid has no credits, only THAT side's frame is dropped; the other keeps playing.
//
// SAFETY: same as everywhere: every source clamps its samples to Safety.hardPeak, volume is
// clamped, nothing is sent to an aid before it acknowledges Start, Ctrl-C sends Stop.

import Foundation
import CoreBluetooth

/// Two independent test tones, one per ear (different pitches make it easy to check sides).
final class StereoTone: AudioSource {
    let left: ToneGenerator, right: ToneGenerator
    init(leftHz: Double, rightHz: Double, levelDbfs: Double, seconds: Double) {
        left = ToneGenerator(frequency: leftHz, levelDbfs: levelDbfs, seconds: seconds)
        right = ToneGenerator(frequency: rightHz, levelDbfs: levelDbfs, seconds: seconds)
    }
    func start() throws {}
    func stop() {}
    var finished: Bool { left.finished && right.finished }
    var statusLine: String { "" }
    func next(_ count: Int) -> [Int16] { left.next(count) }          // (unused here)
    func nextStereo(_ count: Int) -> (left: [Int16], right: [Int16]) { (left.next(count), right.next(count)) }
}

final class BinauralStreamer: NSObject, CBCentralManagerDelegate {
    let cfg: StreamSettings
    let source: AudioSource
    let sourceInfo: [String]
    private var central: CBCentralManager!
    private var links: [UUID: AidLink] = [:]

    enum Phase { case setup, countdown, streaming, stopping, done }
    private(set) var phase = Phase.setup

    private var timer: DispatchSourceTimer?
    private var seq: UInt8 = 0
    private var streamStart: UInt64 = 0
    private var slotsDone = 0, skippedLate = 0, tailFrames = 0
    private var maxLatenessMs = 0.0

    /// If set, the Mac's volume slider/keys control the aids' volume (see VolumeKeys.swift).
    var volumeKeys: VolumeKeys?
    /// The ASHA volume currently in use (from the keys, or cfg.volume).
    private var volume: Int8 = -127

    init(cfg: StreamSettings, source: AudioSource, sourceInfo: [String]) {
        self.cfg = cfg
        self.source = source
        self.sourceInfo = sourceInfo
        super.init()
    }

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    private var live: [AidLink] { links.values.filter { $0.state != .closed } }
    private var ready: [AidLink] { links.values.filter { $0.state == .ready } }
    private var streaming: [AidLink] { links.values.filter { $0.state == .streaming } }

    // MARK: Bluetooth on -> connect both known aids directly (no scan)

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            if c.state == .unauthorized || c.state == .poweredOff { fail("Bluetooth is off or not permitted.") }
            return
        }
        for side in [Side.left, .right] {
            guard let k = KnownAids.find(side: side), let id = UUID(uuidString: k.id),
                  let p = c.retrievePeripherals(withIdentifiers: [id]).first else {
                log("No known \(side.rawValue.uppercased()) aid. (Run `asha-probe \(side.rawValue)` once to pair and remember it.)")
                continue
            }
            let link = AidLink(side: side, peripheral: p, central: c, latencyLevel: cfg.latency)
            link.onReady = { [unowned self] _ in maybeBegin() }
            link.onStarted = { [unowned self] l, ok in started(l, ok) }
            link.onClosed = { [unowned self] l, why in closed(l, why) }
            links[p.identifier] = link
            link.connect()
        }
        guard !links.isEmpty else { fail("No known aids at all.") }
        // Don't wait forever for a second aid: after 20 s, carry on with whatever is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.phase == .setup else { return }
            if self.ready.isEmpty { self.stopAll("no aid became ready within 20 s"); return }
            log("Only \(self.ready.map { $0.side.rawValue }.joined()) is ready after 20 s; continuing with one aid.")
            self.beginCountdown()
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { links[p.identifier]?.didConnect() }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { links[p.identifier]?.close("connect failed") }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        links[p.identifier]?.didDisconnect(error)
    }

    // MARK: Start-up

    /// Begin as soon as every aid we're trying is either ready or has given up.
    private func maybeBegin() {
        guard phase == .setup else { return }
        if links.values.allSatisfy({ $0.state == .ready || $0.state == .closed }) && !ready.isEmpty { beginCountdown() }
    }

    private func beginCountdown() {
        phase = .countdown
        volume = volumeKeys?.current ?? cfg.volume
        volumeKeys?.onChange = { [weak self] v in self?.volumeChanged(v) }
        let sides = ready.map { $0.side.rawValue.uppercased() }.sorted().joined(separator: " + ")
        log("READY: \(sides). Volume \(volume) (\(String(format: "%.1f", Safety.volumeDb(volume))) dB)" + (volumeKeys != nil ? " from the Mac's volume keys (top = \(volumeKeys!.maxVolume))" : "") + ", \(cfg.frameMs) ms frames.")
        sourceInfo.forEach { log("       " + $0) }
        log("       SAFETY: aids OUT of your ears for the first run of new audio code. Ctrl-C now to abort. Starting in 3 s…")
        do { try source.start() } catch { stopAll("audio source failed: \(error.localizedDescription)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard phase == .countdown else { return }
            let both = ready.count == 2
            for l in ready { l.setVolume(volume); if cfg.sendStatus { l.sendConnParamsUpdated(intervalUnits: cfg.intervalUnits) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                guard phase == .countdown else { return }
                for l in ready { l.start(volume: volume, otherSideStreaming: both) }
            }
        }
    }

    private func started(_ l: AidLink, _ ok: Bool) {
        if !ok { l.stop {} ; return }
        if phase == .countdown { beginStreaming() }
        // A second aid that acks later simply starts receiving the next packets (same sequence counter).
    }

    // MARK: Streaming

    private func beginStreaming() {
        phase = .streaming
        streamStart = DispatchTime.now().uptimeNanoseconds
        log("STREAMING" + (cfg.maxSeconds > 0 ? " for \(cfg.maxSeconds) s" : ". Ctrl-C to stop") + "…")
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(cfg.frameMs), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        func report() {
            guard phase == .streaming else { return }
            let perSide = links.values.sorted { $0.side.rawValue < $1.side.rawValue }
                .map { "\($0.side.rawValue.uppercased()) \($0.state) sent \($0.sent) drop \($0.droppedNoSpace)" }.joined(separator: " | ")
            let extra = source.statusLine
            log("   \(perSide) | late-skips \(skippedLate), max lateness \(String(format: "%.1f", maxLatenessMs)) ms" + (extra.isEmpty ? "" : " | " + extra))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: report)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: report)
    }

    private func tick() {
        guard phase == .streaming else { return }
        let frameNs = UInt64(cfg.frameMs) * 1_000_000
        let elapsed = DispatchTime.now().uptimeNanoseconds - streamStart
        if cfg.maxSeconds > 0 && Double(elapsed) / 1e9 >= cfg.maxSeconds { stopAll("--seconds reached"); return }
        let due = Int(elapsed / frameNs) + 1
        maxLatenessMs = max(maxLatenessMs, Double(elapsed % frameNs) / 1e6)
        if due - slotsDone > 3 {                       // far behind: skip ahead instead of bursting old audio
            let skip = due - slotsDone - 1
            skippedLate += skip
            _ = source.nextStereo(skip * samplesPerFrame(frameMs: cfg.frameMs))
            slotsDone += skip
        }
        while slotsDone < due && phase == .streaming {
            sendFrame()
            slotsDone += 1
        }
    }

    private func sendFrame() {
        if source.finished { tailFrames += 1; if tailFrames > 10 { stopAll("source finished"); return } }
        let n = samplesPerFrame(frameMs: cfg.frameMs)
        let (l, r) = source.nextStereo(n)
        for link in streaming { link.send(seq: seq, pcm: link.side == .left ? l : r) }
        seq &+= 1        // shared by both ears, like Android
    }

    // MARK: Volume keys

    private func volumeChanged(_ v: Int8) {
        guard phase == .countdown || phase == .streaming, v != volume else { return }
        volume = v
        log("Volume keys -> aid volume \(v) (\(v == -128 ? "muted" : String(format: "%.1f dB", Safety.volumeDb(v))))")
        for l in live where l.state == .ready || l.state == .starting || l.state == .streaming { l.setVolume(v) }
    }

    // MARK: One aid drops out / stopping

    private func closed(_ l: AidLink, _ why: String) {
        if phase == .stopping || phase == .done { return }
        // Tell the remaining aid its partner is gone (Android: 03 00), then carry on with it.
        for other in live where other !== l && (other.state == .streaming || other.state == .ready) {
            other.sendOtherSide(connected: false)
        }
        if live.isEmpty { stopAll("all aids disconnected (\(why))") }
        else if phase == .setup { maybeBegin() }
    }

    func stopAll(_ reason: String) {
        guard phase != .stopping && phase != .done else { return }
        phase = .stopping
        timer?.cancel(); timer = nil
        source.stop()
        log("STOPPING (\(reason)).")
        let all = Array(links.values)
        var remaining = all.count
        if remaining == 0 { finish() }
        for link in all {
            log("   \(link.side.rawValue.uppercased()): sent \(link.sent), dropped(no space) \(link.droppedNoSpace)")
            link.stop { [weak self] in remaining -= 1; if remaining == 0 { self?.finish() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish() }   // never hang on exit
    }

    private func finish() {
        guard phase != .done else { return }
        phase = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { log("Done."); exit(0) }
    }
}
