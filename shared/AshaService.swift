// AshaService.swift — step C: the always-running background service.
//
// What it does, continuously:
//   * Keeps BOTH known aids connected. CoreBluetooth's connect() has no time limit: it
//     waits until the aid shows up, so "auto-connect when the aids come into range" is
//     just "call connect() again whenever a link closes".
//   * When streaming is switched ON (ashactl on) it captures the Mac's stereo audio (speakers
//     muted while capturing) and, only while something is actually PLAYING, sends Start to the
//     aids and streams. After `idleSeconds` of silence it sends Stop (staying connected), so the
//     aids return to normal listening with their microphones at full strength. Android behaves
//     the same way (Start when playback starts, Stop when it stops).
//   * The Mac's volume keys control the aids' volume (VolumeKeys).
//   * Writes its state to ~/.config/asha-mac/status.json and listens for commands sent by
//     `ashactl` (macOS "distributed notifications": a simple broadcast between programs).
//
// SAFETY: the same chain as asha-binaural: linked limiter + hard clamp at the ceiling (-6 dBFS),
// aid volume from the keys (max --max-volume, default 0), nothing sent before an aid acks Start.

import Foundation
import CoreBluetooth

final class AshaService: NSObject, CBCentralManagerDelegate {
    // Settings
    let frameMs = 20, intervalUnits: UInt8 = 16
    let idleSeconds: Double
    let latencyLevel: Int? = 0
    let maxVolume: Int8

    // Persistent on/off switch.
    private(set) var enabled: Bool { didSet { saveSettings(); writeStatus() } }

    private var central: CBCentralManager!
    private var links: [Side: AidLink] = [:]
    private var peripherals: [Side: CBPeripheral] = [:]
    private let keys: VolumeKeys
    private var volume: Int8 = -127

    // Capture + streaming session.
    private var source: SystemAudioSource?
    private var timer: DispatchSourceTimer?
    private var seq: UInt8 = 0
    private var streamStart: UInt64 = 0
    private var slotsDone = 0
    private var monitor: DispatchSourceTimer?
    /// Sides whose Start is scheduled but not sent yet (so the 4×/s check doesn't start them twice).
    private var pendingStart: Set<Side> = []

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/asha-mac")
    static let settingsURL = dir.appendingPathComponent("service.json")
    static let statusURL = dir.appendingPathComponent("status.json")
    static let commandName = Notification.Name("local.asha.command")
    /// UID of the hidden input of our "Hearing Aids" driver (kDevice2_UID = kDriver_Name "_2_UID").
    static let monitorUID = "ASHA Hearing Aids_2_UID"

    init(idleSeconds: Double, maxVolume: Int8) {
        self.idleSeconds = idleSeconds
        self.maxVolume = maxVolume
        keys = VolumeKeys(maxVolume: maxVolume)
        let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.settingsURL))) as? [String: Any]
        enabled = saved?["enabled"] as? Bool ?? true
        super.init()
    }

    func start() {
        log("ASHA service starting. Streaming is \(enabled ? "ON" : "OFF"). Idle stop after \(Int(idleSeconds)) s of silence.")
        keys.onChange = { [weak self] v in self?.volumeChanged(v) }
        keys.start()
        volume = keys.current
        DistributedNotificationCenter.default().addObserver(forName: Self.commandName, object: nil, queue: .main) { [weak self] n in
            self?.command(n.object as? String ?? "")
        }
        central = CBCentralManager(delegate: self, queue: nil)
        // Every 0.25 s: start or stop streaming depending on whether sound is playing; refresh status.
        let m = DispatchSource.makeTimerSource(queue: .main)
        m.schedule(deadline: .now() + 1, repeating: .milliseconds(250))
        m.setEventHandler { [weak self] in self?.checkActivity() }
        monitor = m
        m.resume()
        writeStatus()
    }

    // MARK: Commands from ashactl

    private func command(_ c: String) {
        log("Command: \(c)")
        switch c {
        case "on": enabled = true; ensureCapture()
        case "off": enabled = false; pauseAll(); stopCapture()
        case "status": writeStatus()
        case "quit": shutdown()
        default: log("Unknown command '\(c)'")
        }
    }

    // MARK: Bluetooth

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { log("Bluetooth state \(c.state.rawValue) (waiting for ON)."); writeStatus(); return }
        for side in [Side.left, .right] {
            guard let k = KnownAids.find(side: side), let id = UUID(uuidString: k.id),
                  let p = c.retrievePeripherals(withIdentifiers: [id]).first else {
                log("No known \(side.rawValue) aid; run `asha-probe \(side.rawValue)` once to pair it.")
                continue
            }
            peripherals[side] = p
            makeLink(side)
        }
        // Capture (which mutes the speakers) starts only once an aid is actually connected; see ensureCapture().
    }

    private func makeLink(_ side: Side) {
        guard let p = peripherals[side], let central else { return }
        let link = AidLink(side: side, peripheral: p, central: central, latencyLevel: latencyLevel)
        link.onReady = { [weak self] l in self?.ensureCapture(); self?.writeStatus(); self?.checkActivity() }
        link.onStarted = { [weak self] l, ok in self?.started(l, ok) }
        link.onBattery = { [weak self] _ in self?.writeStatus() }
        link.onClosed = { [weak self] l, why in self?.closed(l, why) }
        links[side] = link
        link.connect()          // waits as long as needed for the aid to appear
        writeStatus()
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { link(for: p)?.didConnect() }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { link(for: p)?.close("connect failed") }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { link(for: p)?.didDisconnect(error) }
    private func link(for p: CBPeripheral) -> AidLink? { links.values.first { $0.peripheral.identifier == p.identifier } }

    private func closed(_ l: AidLink, _ why: String) {
        guard links[l.side] === l else { return }
        links[l.side] = nil
        // Tell the other aid its partner is gone (Android: 03 00).
        if let other = links[l.side == .left ? .right : .left], [.ready, .starting, .streaming].contains(other.state) {
            other.sendOtherSide(connected: false)
        }
        if !links.values.contains(where: { $0.state == .streaming }) { stopTimer() }
        // No aid connected any more: release the capture so the Mac's own speakers play again.
        if !anyAidConnected { stopCapture() }
        writeStatus()
        guard !shuttingDown else { return }
        // Reconnect: a fresh link waits for the aid to come back (out of range, asleep, or busy with the phone).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.links[l.side] == nil, !self.shuttingDown else { return }
            self.makeLink(l.side)
        }
    }

    // MARK: Activity: start when sound plays, stop after idleSeconds of silence

    private func checkActivity() {
        guard enabled, let source else { writeStatusThrottled(); return }
        let quietFor = source.secondsSinceSound
        let ready = links.values.filter { $0.state == .ready }
        let active = links.values.filter { $0.state == .streaming || $0.state == .starting }
        if quietFor < 0.5 {
            // Sound is playing: start every connected aid that isn't streaming yet, exactly once.
            for l in ready where !pendingStart.contains(l.side) {
                pendingStart.insert(l.side)
                l.setVolume(volume)
                l.sendConnParamsUpdated(intervalUnits: intervalUnits)
                // Pause so a status reply can't be mistaken for the reply to Start (as in all our tools).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.pendingStart.remove(l.side)
                    guard l.state == .ready, self.links[l.side] === l else { return }
                    let other = self.links[l.side == .left ? .right : .left]
                    let otherOn = other.map { [.ready, .starting, .streaming].contains($0.state) } ?? false
                    l.start(volume: self.volume, otherSideStreaming: otherOn)
                    // A partner that is already streaming is told this side has (re)joined (Android: 03 01).
                    if let other, other.state == .streaming { other.sendOtherSide(connected: true) }
                }
            }
        } else if quietFor > idleSeconds && !active.isEmpty {
            log("Silent for \(Int(idleSeconds)) s: pausing the aids (still connected).")
            pauseAll()
        }
        writeStatusThrottled()
    }

    private func started(_ l: AidLink, _ ok: Bool) {
        if !ok { l.close("Start not acknowledged"); return }      // reconnect logic takes over
        if timer == nil { startTimer() }
        writeStatus()
    }

    private func pauseAll() {
        for l in links.values { l.pause() }
        stopTimer()
    }

    // MARK: Capture

    /// True if at least one aid has a working audio channel (ready, starting or streaming).
    private var anyAidConnected: Bool { links.values.contains { [.ready, .starting, .streaming].contains($0.state) } }

    /// Start capturing (this MUTES the Mac's speakers), but only when streaming is ON *and* an aid is
    /// connected to receive the sound. Otherwise the Mac would go silent with nowhere for the audio to go
    /// (e.g. aids switched off or in another room). Found while testing the service on 2026-10-06.
    private func ensureCapture() {
        guard enabled, source == nil, anyAidConnected else { return }
        // Full gain + -6 dBFS ceiling; the volume keys do the attenuation (same as asha-binaural --source system).
        Safety.setCeiling(-6)
        // Preferred: the "Hearing Aids" output device (driver/). Apps play to it like AirPods, and we
        // read its hidden monitor input. Fallback when it isn't installed: tap all system audio and mute the speakers.
        let useDevice = SystemAudioSource.deviceID(forUID: Self.monitorUID) != nil
        let s = useDevice ? SystemAudioSource(gainDb: 0, bufferMs: 30, stereo: true, deviceUID: Self.monitorUID)
                          : SystemAudioSource(gainDb: 0, bufferMs: 30, muteLocal: true, stereo: true)
        do { try s.start(); source = s } catch { log("Capture failed: \(error.localizedDescription)") }
        writeStatus()
    }

    private func stopCapture() { source?.stop(); source = nil; writeStatus() }

    // MARK: Streaming clock (same as BinauralStreamer)

    private func startTimer() {
        seq = 0                     // each Start resets the aids' decoders; the counter starts again too
        slotsDone = 0
        streamStart = DispatchTime.now().uptimeNanoseconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(frameMs), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        log("Streaming.")
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    private func tick() {
        guard let source else { return }
        let frameNs = UInt64(frameMs) * 1_000_000
        let due = Int((DispatchTime.now().uptimeNanoseconds - streamStart) / frameNs) + 1
        if due - slotsDone > 3 {                           // far behind: skip rather than burst old audio
            _ = source.nextStereo((due - slotsDone - 1) * samplesPerFrame(frameMs: frameMs))
            slotsDone = due - 1
        }
        while slotsDone < due {
            let (l, r) = source.nextStereo(samplesPerFrame(frameMs: frameMs))
            for link in links.values where link.state == .streaming { link.send(seq: seq, pcm: link.side == .left ? l : r) }
            seq &+= 1
            slotsDone += 1
        }
    }

    // MARK: Volume keys

    private func volumeChanged(_ v: Int8) {
        volume = v
        for l in links.values where [.ready, .starting, .streaming].contains(l.state) { l.setVolume(v) }
        writeStatus()
    }

    // MARK: Status file + settings

    private var lastStatusWrite = Date.distantPast
    private var lastBattery: [Side: Int] = [:]
    private func writeStatusThrottled() { if Date().timeIntervalSince(lastStatusWrite) > 2 { writeStatus() } }

    private func writeStatus() {
        lastStatusWrite = Date()
        var aids: [String: Any] = [:]
        for side in [Side.left, .right] {
            let l = links[side]
            // Remember the last known battery level across reconnects (a link object is replaced on reconnect).
            if let b = l?.batteryPercent { lastBattery[side] = b }
            aids[side.rawValue] = ["state": l.map { "\($0.state)" } ?? "NOT KNOWN", "sent": l?.sent ?? 0, "dropped": l?.droppedNoSpace ?? 0,
                                   "battery": lastBattery[side] ?? -1]
        }
        let st: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier,
            "enabled": enabled, "capturing": source != nil, "streaming": timer != nil,
            "volume": Int(volume), "maxVolume": Int(maxVolume), "secondsSinceSound": source.map { min($0.secondsSinceSound, 99999) } ?? -1,
            "aids": aids,
        ]
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: Self.statusURL) }
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: ["enabled": enabled], options: .prettyPrinted) { try? d.write(to: Self.settingsURL) }
    }

    // MARK: Shutdown

    private var shuttingDown = false
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        log("Shutting down: Stop to the aids, release capture.")
        stopTimer()
        source?.stop(); source = nil
        var remaining = links.count
        if remaining == 0 { exit(0) }
        for l in links.values { l.stop { remaining -= 1; if remaining == 0 { log("Bye."); exit(0) } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    }
}
