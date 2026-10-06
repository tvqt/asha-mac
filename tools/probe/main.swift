// main.swift (asha-probe) — Phase 1 ASHA feasibility probe for macOS
//
// WHAT IT DOES:
//   1. Finds a hearing aid and connects (shared/AidFinder.swift). macOS pairs
//      automatically if the aid asks for encryption; a pop-up may appear.
//   2. Lists every GATT service and characteristic the aid offers. Reads and
//      decodes the ASHA ones and the standard Device Information ones.
//   3. Opens the L2CAP connection-oriented channel (CoC, like a TCP socket for
//      Bluetooth) on the PSM (its "port number") the aid gives us. Audio will
//      flow over this channel in Phase 2.
//   4. Holds the connection for 20 s, then disconnects cleanly.
//
// SAFETY: sends NO audio. It never writes to AudioControlPoint or Volume. The
// only write is the standard "notify me of AudioStatus changes" switch.
//
// USAGE:   asha-probe [left|right|any]   probe one aid (default: any)
//          asha-probe scan               list ALL nearby BLE devices' adverts

import Foundation
import CoreBluetooth

/// How long to hold the L2CAP channel open before disconnecting.
let holdSeconds = 20.0

final class Probe: NSObject, CBPeripheralDelegate, StreamDelegate {
    let finder: AidFinder
    var servicesLeft = 0            // services whose characteristics are still being listed
    var props: AshaProperties?
    var psm: UInt16?
    var l2capRequested = false
    var channel: CBL2CAPChannel?    // keeping a reference keeps the channel open
    var finishing = false

    init(finder: AidFinder) {
        self.finder = finder
        super.init()
        finder.onConnected = { [unowned self] p in
            // Reset per-aid state (we may be on our second candidate).
            props = nil; psm = nil; l2capRequested = false
            p.delegate = self                 // this aid's callbacks now come to us
            if let lvl = requestedLatency { finder.setDesiredConnectionLatency(lvl, for: p) }
            // Discover ALL services (nil), to get a full picture of the aid.
            p.discoverServices(nil)
        }
        finder.onDisconnected = { [unowned self] _, error in
            if finishing { log("Disconnected cleanly."); return }
            fail("disconnected unexpectedly: \(error?.localizedDescription ?? "no reason given")", code: 4)
        }
    }

    // MARK: Services and characteristics

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("discovering services: \(error.localizedDescription)", code: 5) }
        let services = p.services ?? []
        log("Discovered \(services.count) GATT services:")
        for s in services { log("  service \(name(s.uuid))") }
        // ATT MTU check: the biggest GATT packet, minus a 3-byte header.
        log("Max GATT write size (ATT MTU - 3): \(p.maximumWriteValueLength(for: .withoutResponse)) bytes")
        if services.contains(where: { $0.uuid == ashaServiceUUID }) {
            log("RESULT: ASHA service (FDF0) IS present in the GATT database.")
        } else {
            log("RESULT: NO ASHA service (FDF0) in this aid's GATT database. Record in docs/FINDINGS.md.")
        }
        servicesLeft = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("  (couldn't list characteristics of \(name(service.uuid)): \(error.localizedDescription))") }
        for c in service.characteristics ?? [] {
            log("  \(name(service.uuid)) -> \(name(c.uuid)) [\(describeProperties(c.properties))]")
            // Read only the values we care about. Reading is harmless.
            if [readOnlyPropsUUID, psmUUID, audioStatusUUID, manufacturerUUID, modelUUID, firmwareUUID].contains(c.uuid) {
                p.readValue(for: c)
            }
            if c.uuid == audioStatusUUID && c.properties.contains(.notify) {
                p.setNotifyValue(true, for: c)
            }
        }
        servicesLeft -= 1
        if servicesLeft == 0 { log("All characteristics listed. Waiting for read results… (accept any pairing pop-up)") }
    }

    /// A read finished, or a subscribed value was pushed to us.
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            // "Insufficient authentication" = pair first. macOS usually starts
            // pairing on its own (pop-up). Retry after a pause.
            log("READ ERROR on \(name(c.uuid)): \(error.localizedDescription). Retrying in 5 s (accept any pairing pop-up).")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { p.readValue(for: c) }
            return
        }
        guard let v = c.value else { return }
        switch c.uuid {
        case readOnlyPropsUUID:
            guard let pr = AshaProperties(v) else { log("ReadOnlyProperties too short: \(hex(v))"); return }
            pr.describe().forEach { log($0) }
            // Remember this aid's side. If it's the wrong one, the finder
            // disconnects and tries the next candidate.
            guard finder.checkSide(pr, of: p) else { return }
            props = pr
        case psmUUID:
            log("LE_PSM_OUT raw: \(hex(v))")
            if v.count == 2 {
                psm = le16(v, 0)
                log("  -> audio L2CAP PSM = \(psm!) (0x\(String(format: "%04x", psm!)))")
            }
        case audioStatusUUID:
            log("AudioStatus: \(hex(v))" + (v.isEmpty ? "" : "  (\(describeAudioStatus(v[v.startIndex])))"))
        case manufacturerUUID, modelUUID, firmwareUUID:
            log("\(knownNames[c.uuid]!): \"\(String(decoding: v, as: UTF8.self))\"")
        default:
            log("value of \(name(c.uuid)): \(hex(v))")
        }
        maybeOpenL2CAP(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        log(error == nil ? "Subscribed to \(name(c.uuid)) notifications."
                         : "Could not subscribe to \(name(c.uuid)): \(error!.localizedDescription)")
    }

    // MARK: L2CAP

    /// Open the channel once we have both the properties (right side) and the PSM.
    func maybeOpenL2CAP(_ p: CBPeripheral) {
        guard props != nil, let psm, !l2capRequested else { return }
        l2capRequested = true
        log("Opening L2CAP CoC channel on PSM \(psm)…")
        p.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard error == nil, let ch = channel else {
            log("L2CAP OPEN FAILED: \(error.map { "\($0)" } ?? "no channel returned")")
            finish(after: 2)
            return
        }
        self.channel = ch
        log("L2CAP CHANNEL OPEN on PSM \(ch.psm).")
        // The channel appears as a pair of byte streams. Open them and log
        // their events, but write NOTHING.
        for s in [ch.inputStream as Stream?, ch.outputStream as Stream?].compactMap({ $0 }) {
            s.delegate = self
            s.schedule(in: .main, forMode: .default)   // deliver events on the main thread
            s.open()
        }
        log("Holding the connection for \(Int(holdSeconds)) s…")
        finish(after: holdSeconds)
    }

    func stream(_ s: Stream, handle event: Stream.Event) {
        let which = (s is InputStream) ? "input" : "output"
        switch event {
        case .openCompleted: log("  L2CAP \(which) stream opened")
        case .hasSpaceAvailable: log("  L2CAP output stream has space available (not sending anything)")
        case .hasBytesAvailable:
            if let input = s as? InputStream {
                var buf = [UInt8](repeating: 0, count: 512)
                let n = input.read(&buf, maxLength: buf.count)
                if n > 0 { log("  L2CAP received \(n) bytes: \(hex(Array(buf[0..<n])))") }
            }
        case .errorOccurred: log("  L2CAP \(which) stream ERROR: \(s.streamError?.localizedDescription ?? "?")")
        case .endEncountered: log("  L2CAP \(which) stream closed by the aid")
        default: break
        }
    }

    // MARK: Clean-up

    func finish(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            log("Closing channel and disconnecting…")
            finishing = true
            channel?.inputStream?.close()
            channel?.outputStream?.close()
            channel = nil
            finder.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { log("Done."); exit(0) }
        }
    }
}

/// Turn a characteristic's property flags into words, e.g. "read notify".
func describeProperties(_ p: CBCharacteristicProperties) -> String {
    var w: [String] = []
    if p.contains(.read) { w.append("read") }
    if p.contains(.write) { w.append("write") }
    if p.contains(.writeWithoutResponse) { w.append("write-no-response") }
    if p.contains(.notify) { w.append("notify") }
    if p.contains(.indicate) { w.append("indicate") }
    return w.joined(separator: " ")
}

// MARK: - Scan-only mode: print every nearby device's advert

var lastPrinted: [UUID: String] = [:]    // print each distinct advert once
var heard: [UUID: (rssi: Int, summary: String)] = [:]

func dumpAdvert(_ p: CBPeripheral, _ ad: [String: Any], _ rssi: Int) {
    // Skip "RSSI unavailable" (127) and far-away devices (weaker than -80 dBm).
    guard rssi != 127, rssi > -80 else { return }
    var parts: [String] = []
    parts.append("name=\"\((ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "(no name)")\"")
    if let u = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !u.isEmpty {
        parts.append("services=[\(u.map { $0.uuidString }.joined(separator: ", "))]")
    }
    if let sd = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !sd.isEmpty {
        parts.append("serviceData={" + sd.map { "\($0.key.uuidString): \(hex($0.value))" }.sorted().joined(separator: "; ") + "}")
    }
    // Manufacturer data starts with a 2-byte company ID (e.g. 0x004C = Apple).
    if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data {
        parts.append("manufacturer=" + (m.count >= 2 ? String(format: "0x%04x", le16(m, 0)) : "?") + " data=\(hex(m))")
    }
    if let c = ad[CBAdvertisementDataIsConnectable] as? NSNumber { parts.append(c.boolValue ? "connectable" : "not-connectable") }
    if let side = KnownAids.side(of: p.identifier) { parts.append("[known \(side.rawValue.uppercased()) aid]") }
    let summary = parts.joined(separator: "  ")
    if rssi > (heard[p.identifier]?.rssi ?? -999) { heard[p.identifier] = (rssi, summary) }
    if lastPrinted[p.identifier] != summary {
        lastPrinted[p.identifier] = summary
        log("\(String(format: "%4d", rssi)) dBm  id=\(p.identifier.uuidString.prefix(8))  \(summary)")
    }
}

// MARK: - Program entry point

/// Objects that must stay alive for the whole run. Swift frees an object as
/// soon as nothing refers to it, and CoreBluetooth only keeps weak references.
var keepAlive: [AnyObject] = []

// Optional experiment flag "--ci N": ask for connection interval N (units of 1.25 ms).
var cliArgs = Array(CommandLine.arguments.dropFirst())
var requestedCI: Int?
var requestedLatency: Int?   // "--latency N": EXPERIMENT, private setDesiredConnectionLatency
if let i = cliArgs.firstIndex(of: "--latency"), i + 1 < cliArgs.count, let n = Int(cliArgs[i + 1]) {
    requestedLatency = n
    cliArgs.removeSubrange(i...(i + 1))
}
if let i = cliArgs.firstIndex(of: "--ci"), i + 1 < cliArgs.count, let n = Int(cliArgs[i + 1]) {
    requestedCI = n
    cliArgs.removeSubrange(i...(i + 1))
}
let arg = cliArgs.first?.lowercased() ?? "any"
log("asha-probe starting (\(arg)). This probe sends NO audio.")

if arg == "scan" {
    let finder = AidFinder(wanted: .any)
    finder.advertObserver = dumpAdvert
    finder.onScanOnlyFinished = {
        log("Scan finished. \(heard.count) devices heard above -80 dBm, strongest first:")
        for (id, h) in heard.sorted(by: { $0.value.rssi > $1.value.rssi }) {
            log("\(String(format: "%4d", h.rssi)) dBm  id=\(id.uuidString.prefix(8))  \(h.summary)")
        }
        exit(0)
    }
    keepAlive = [finder]
    finder.start()
} else {
    guard let side = Side(rawValue: arg) else {
        print("Usage: asha-probe [left|right|any|scan]")
        exit(64)
    }
    let finder = AidFinder(wanted: side)
    if let ci = requestedCI { finder.setRequestedInterval(units: ci) }
    let probe = Probe(finder: finder)
    keepAlive = [finder, probe]
    finder.start()
    // Safety net: never hang forever waiting for a callback that doesn't come.
    DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
        fail("TIMEOUT after 150 s. Copy the log above into the chat.", code: 9)
    }
}

// Run the main event loop forever; CoreBluetooth delivers callbacks through it.
RunLoop.main.run()
