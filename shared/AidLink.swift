// AidLink.swift — Phase 4: one hearing aid's connection, usable two at a time.
//
// The same steps as AshaStreamer (proven in Phases 2-3), but split so a
// coordinator (BinauralStreamer) can drive TWO aids together:
//   connect -> ask for the 20 ms link -> read ReadOnlyProperties + PSM ->
//   subscribe to AudioStatus -> open the L2CAP audio channel -> READY
//   then on request: volume, status messages, Start (wait for AudioStatus 0),
//   send audio packets, Stop.
//
// A CBCentralManager can only have ONE delegate, so connection events (connected,
// disconnected) arrive at the coordinator, which forwards them here by device ID.
// Everything runs on the main thread.

import Foundation
import CoreBluetooth

final class AidLink: NSObject, CBPeripheralDelegate, StreamDelegate {
    let side: Side
    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?
    /// Private latency level to request right after connecting (0 -> 20 ms with our bluetoothd settings).
    let latencyLevel: Int?

    enum State: CustomStringConvertible {
        case idle, connecting, setup, ready, starting, streaming, stopping, closed
        // Spelled out explicitly. (Writing "\(self)" here would call this same property
        // again, forever: that recursion crashed the first binaural run on 2026-10-06.)
        var description: String {
            switch self {
            case .idle: return "IDLE"
            case .connecting: return "CONNECTING"
            case .setup: return "SETUP"
            case .ready: return "READY"
            case .starting: return "STARTING"
            case .streaming: return "STREAMING"
            case .stopping: return "STOPPING"
            case .closed: return "CLOSED"
            }
        }
    }
    private(set) var state = State.idle

    // GATT handles and values.
    private var controlPoint: CBCharacteristic?
    private var volumeChar: CBCharacteristic?
    private(set) var props: AshaProperties?
    private var psm: UInt16?
    private var statusSubscribed = false
    private var channelRequested = false
    private var channel: CBL2CAPChannel?
    private var output: OutputStream? { channel?.outputStream }

    /// Battery level in percent (nil = not known yet). BATTERY_10 aids report in 10 % steps.
    private(set) var batteryPercent: Int?
    var onBattery: (AidLink) -> Void = { _ in }
    private var hasBattery100 = false

    // Start handshake.
    private var startWriteOK = false, startAcked = false

    // Callbacks for the coordinator.
    var onReady: (AidLink) -> Void = { _ in }
    var onStarted: (AidLink, Bool) -> Void = { _, _ in }          // Bool = acknowledged OK
    var onClosed: (AidLink, String) -> Void = { _, _ in }

    // Per-aid G.722 encoder: each ear is its own continuous stream with its own codec state.
    // Replaced at every Start, because Start tells the aid to reset ITS decoder ("reset the
    // codec and start the playback of frame 0"); both ends must begin from a fresh state.
    private(set) var encoder = G722Encoder()
    // Statistics.
    private(set) var sent = 0, droppedNoSpace = 0

    init(side: Side, peripheral: CBPeripheral, central: CBCentralManager, latencyLevel: Int?) {
        self.side = side
        self.peripheral = peripheral
        self.central = central
        self.latencyLevel = latencyLevel
        super.init()
        peripheral.delegate = self
    }

    private func say(_ s: String) { log("[\(side.rawValue.uppercased())] " + s) }

    // MARK: Connection (events forwarded by the coordinator)

    func connect() {
        state = .connecting
        say("Connecting…")
        central?.connect(peripheral, options: nil)
    }

    func didConnect() {
        state = .setup
        say("Connected.")
        if let lvl = latencyLevel, let central { setDesiredConnectionLatencyPrivate(central, lvl, peripheral) }
        // ASHA for audio, plus the MFi service, which holds the battery level.
        peripheral.discoverServices([ashaServiceUUID, mfiHearingUUID])
        // The aid may refuse the audio channel if another device (the phone) is streaming to it.
        // macOS doesn't report that refusal, so time out with a hint (seen in the HCI trace, 2026-10-06).
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.state == .setup else { return }
            self.close("audio channel not opened within 15 s (aid busy with your phone? turn its Bluetooth off)")
        }
    }

    func didDisconnect(_ error: Error?) {
        guard state != .closed else { return }
        let why = error?.localizedDescription ?? "disconnected"
        state = .closed
        say("Link closed: \(why)")
        onClosed(self, why)
    }

    // MARK: GATT setup

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p.services?.contains(where: { $0.uuid == ashaServiceUUID }) == true else {
            close("no ASHA service (\(error?.localizedDescription ?? "not found"))"); return
        }
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if service.uuid == mfiHearingUUID {
            // Battery: prefer the percent characteristic; else the 0-10 one. Read now, then follow changes.
            let chars = service.characteristics ?? []
            hasBattery100 = chars.contains { $0.uuid == battery100UUID }
            for c in chars where c.uuid == (hasBattery100 ? battery100UUID : battery10UUID) {
                p.readValue(for: c)
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            }
            return
        }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case readOnlyPropsUUID, psmUUID: p.readValue(for: c)
            case audioStatusUUID: p.setNotifyValue(true, for: c)
            case audioControlUUID: controlPoint = c
            case volumeUUID: volumeChar = c
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == audioStatusUUID else { return }          // (battery subscription: nothing to do)
        if error != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { p.setNotifyValue(true, for: c) }   // pairing under way: retry
            return
        }
        statusSubscribed = c.isNotifying
        maybeOpenChannel()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if error != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { p.readValue(for: c) }               // pairing under way: retry
            return
        }
        guard let v = c.value else { return }
        if c.uuid == battery100UUID || c.uuid == battery10UUID, let b = v.first {
            let pct = c.uuid == battery100UUID ? Int(b) : Int(b) * 10
            if pct != batteryPercent { batteryPercent = min(pct, 100); say("Battery \(batteryPercent!)% (raw \(b))"); onBattery(self) }
            return
        }
        switch c.uuid {
        case readOnlyPropsUUID:
            guard let pr = AshaProperties(v) else { close("ReadOnlyProperties too short"); return }
            guard pr.side == side else { close("this is the \(pr.side.rawValue) aid, expected \(side.rawValue)"); return }
            guard pr.supportsStreaming, pr.supportsG722_16k else { close("no G.722 streaming support"); return }
            props = pr
        case psmUUID:
            if v.count == 2 { psm = le16(v, 0) }
        case audioStatusUUID:
            handleAudioStatus(v); return
        default: break
        }
        maybeOpenChannel()
    }

    private func maybeOpenChannel() {
        guard props != nil, let psm, statusSubscribed, controlPoint != nil, volumeChar != nil, !channelRequested else { return }
        channelRequested = true
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    func peripheral(_ p: CBPeripheral, didOpen ch: CBL2CAPChannel?, error: Error?) {
        guard error == nil, let ch else { close("L2CAP open failed: \(error?.localizedDescription ?? "no channel")"); return }
        channel = ch
        for s in [ch.inputStream as Stream?, ch.outputStream as Stream?].compactMap({ $0 }) {
            s.delegate = self
            s.schedule(in: .main, forMode: .default)
            s.open()
        }
    }

    func stream(_ s: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted where s === output:
            if state == .setup { state = .ready; say("READY (audio channel open)."); onReady(self) }
        case .hasBytesAvailable:
            if let input = s as? InputStream { var b = [UInt8](repeating: 0, count: 512); _ = input.read(&b, maxLength: b.count) }
        case .errorOccurred: close("audio channel error: \(s.streamError?.localizedDescription ?? "?")")
        case .endEncountered: close("audio channel closed by the aid")
        default: break
        }
    }

    // MARK: Commands

    private func write(_ bytes: [UInt8], to c: CBCharacteristic?, _ type: CBCharacteristicWriteType, _ what: String) {
        guard let c else { return }
        say("-> \(what): \(hex(bytes))")
        peripheral.writeValue(Data(bytes), for: c, type: type)
    }

    func setVolume(_ v: Int8) { write([UInt8(bitPattern: v)], to: volumeChar, .withoutResponse, "Volume") }

    /// "Connection parameters updated" + interval (1.25 ms units), as Android sends after each update.
    func sendConnParamsUpdated(intervalUnits: UInt8) {
        write(AshaCommand.connParamsUpdated(intervalUnits: intervalUnits), to: controlPoint, .withoutResponse, "Status: conn params updated")
    }

    /// Tell this aid whether the OTHER aid is connected (03 01) or has gone (03 00).
    func sendOtherSide(connected: Bool) {
        write([AshaCommand.opStatus, connected ? AshaCommand.statusOtherConnected : AshaCommand.statusOtherDisconnected],
              to: controlPoint, .withoutResponse, "Status: other side \(connected ? "connected" : "disconnected")")
    }

    /// Start [01 01 00 vol otherstate]. onStarted fires when the aid answers AudioStatus (0 = OK).
    func start(volume: Int8, otherSideStreaming: Bool) {
        guard state == .ready else { return }
        state = .starting
        startWriteOK = false; startAcked = false
        encoder = G722Encoder()
        write(AshaCommand.start(volume: volume, otherSideStreaming: otherSideStreaming), to: controlPoint, .withResponse,
              "Start (otherstate \(otherSideStreaming ? 1 : 0))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state == .starting else { return }
            self.say("No AudioStatus reply to Start within 3 s. (Is the link at 20 ms? See docs/FINDINGS.md.)")
            self.state = .ready
            self.onStarted(self, false)
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { say("write failed: \(error.localizedDescription)")
            if state == .starting { state = .ready; onStarted(self, false) }
            if state == .stopping { if pausing { finishPause() } else { finishStop() } }
            return
        }
        if state == .starting { startWriteOK = true; maybeStarted() }
        else if state == .stopping { if pausing { finishPause() } else { finishStop() } }
    }

    private func handleAudioStatus(_ v: Data) {
        guard let raw = v.first else { return }
        say("<- AudioStatus \(hex(v)) (\(describeAudioStatus(raw)))")
        guard state == .starting else { return }
        if raw == 0 { startAcked = true; maybeStarted() } else { state = .ready; onStarted(self, false) }
    }

    private func maybeStarted() {
        guard state == .starting, startWriteOK, startAcked else { return }
        state = .streaming
        say("STREAMING.")
        onStarted(self, true)
    }

    // MARK: Audio

    /// Send one packet. Returns false if it was dropped (no credits). Closes the link on a partial write.
    @discardableResult
    func send(seq: UInt8, pcm: [Int16]) -> Bool {
        guard state == .streaming, let output else { return false }
        let packet = [seq] + encoder.encode(pcm)
        guard output.hasSpaceAvailable else { droppedNoSpace += 1; return false }
        let n = packet.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
        if n != packet.count { close("partial write (\(n) of \(packet.count) bytes); stopping this side for safety"); return false }
        sent += 1
        return true
    }

    // MARK: Pause (Stop, but stay connected)

    private var pausing = false

    /// Send Stop and go back to READY, keeping the connection and audio channel open, so a later
    /// start() resumes quickly. (Android does Stop/Start on the same connection when audio stops/starts.)
    func pause() {
        guard state == .streaming || state == .starting else { return }
        pausing = true
        state = .stopping
        write(AshaCommand.stop(), to: controlPoint, .withResponse, "Stop (pause, staying connected)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishPause() }
    }

    private func finishPause() {
        guard pausing else { return }
        pausing = false
        if state == .stopping { state = .ready; say("Paused (connected, not streaming).") }
    }

    // MARK: Stop / close

    private var stopDone: (() -> Void)?

    /// Send Stop (if streaming), then disconnect. `done` is called once, either way.
    func stop(_ done: @escaping () -> Void) {
        stopDone = done
        if state == .streaming || state == .starting {
            state = .stopping
            write(AshaCommand.stop(), to: controlPoint, .withResponse, "Stop")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishStop() }
        } else {
            finishStop()
        }
    }

    private func finishStop() {
        channel?.outputStream?.close(); channel?.inputStream?.close(); channel = nil
        if state != .closed { state = .closed; central?.cancelPeripheralConnection(peripheral) }
        let d = stopDone; stopDone = nil; d?()
    }

    func close(_ why: String) {
        guard state != .closed else { return }
        say("Closing: \(why)")
        channel?.outputStream?.close(); channel?.inputStream?.close(); channel = nil
        state = .closed
        central?.cancelPeripheralConnection(peripheral)
        onClosed(self, why)
    }
}

/// Call the private -[CBCentralManager setDesiredConnectionLatency:forPeripheral:] (see AidFinder for the full explanation).
func setDesiredConnectionLatencyPrivate(_ central: CBCentralManager, _ level: Int, _ p: CBPeripheral) {
    let sel = NSSelectorFromString("setDesiredConnectionLatency:forPeripheral:")
    guard let m = class_getInstanceMethod(type(of: central), sel) else { log("private latency method missing"); return }
    typealias Fn = @convention(c) (AnyObject, Selector, Int, AnyObject) -> Void
    unsafeBitCast(method_getImplementation(m), to: Fn.self)(central, sel, level, p)
}
