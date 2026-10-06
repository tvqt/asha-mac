// AidFinder.swift — finds a hearing aid and connects to it. Shared by all tools.
//
// How it chooses (see docs/FINDINGS.md for why it has to work this way):
//   1. If we've met the requested side before (KnownAids file), ask macOS for
//      that device by its ID and connect straight to it. Paired aids only
//      advertise their name, so a service-based scan wouldn't recognise them.
//   2. Otherwise scan for a few seconds. Accept devices that advertise ASHA
//      (FDF0), the MFi hearing service, or are already in KnownAids. Skip any
//      known to be the OTHER side. Connect to the best candidate.
//   3. The caller then reads ReadOnlyProperties and calls checkSide(). If it's
//      the wrong aid, we disconnect and try the next candidate.
//
// CoreBluetooth reports results through "delegate" callbacks: we start an
// action (scan, connect…) and the framework later calls one of our methods.
// NSObject is required because the delegate protocols come from Objective-C.

import Foundation
import CoreBluetooth

final class AidFinder: NSObject, CBCentralManagerDelegate {

    let wanted: Side
    let scanSeconds: Double

    /// The "central manager" is the Mac acting as BLE central (the side that
    /// scans and connects, like a phone). Created in start().
    private(set) var central: CBCentralManager!

    /// The aid we're connecting/connected to. Keeping a reference here also
    /// matters: if nothing holds the CBPeripheral, CoreBluetooth drops it.
    private(set) var current: CBPeripheral?

    // Callbacks for the program using this finder:
    /// Connected to a candidate. Set peripheral.delegate, read properties, call checkSide().
    var onConnected: (CBPeripheral) -> Void = { _ in }
    /// The current aid disconnected (and we didn't cause it via rejectCurrent).
    var onDisconnected: (CBPeripheral, Error?) -> Void = { _, _ in }
    /// Scan-only mode: if set, every advert goes here and we connect to nothing.
    var advertObserver: ((CBPeripheral, [String: Any], Int) -> Void)?
    var onScanOnlyFinished: () -> Void = {}

    /// Hearing aids heard during the scan.
    private struct Candidate { let p: CBPeripheral; var rssi: Int; let caps: UInt8?; var name: String }
    private var candidates: [UUID: Candidate] = [:]
    /// Candidates still to try, best first.
    private var queue: [CBPeripheral] = []
    /// Extra options passed to connect(). Used for EXPERIMENTS with private
    /// bluetoothd options (see setRequestedInterval). Empty = macOS defaults.
    var connectOptions: [String: Any] = [:]

    /// True while we're disconnecting a wrong aid on purpose.
    private var rejecting = false
    /// Gives up on a connection attempt that never completes.
    private var connectTimeout: DispatchWorkItem?

    init(wanted: Side, scanSeconds: Double = 8) {
        self.wanted = wanted
        self.scanSeconds = scanSeconds
        super.init()
    }

    /// Create the central manager. macOS checks Bluetooth permission now and
    /// then calls centralManagerDidUpdateState.
    /// queue: nil = deliver callbacks on the main thread (keeps things single-threaded).
    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// The name we've seen for a device: from the advert, else from macOS.
    func displayName(_ p: CBPeripheral) -> String {
        candidates[p.identifier]?.name ?? p.name ?? "(no name)"
    }

    // MARK: Bluetooth state

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth is ON. Permission OK.")
            begin()
        case .unauthorized:
            fail("macOS denied Bluetooth permission. Fix: System Settings > Privacy & Security > Bluetooth > enable your terminal app, then re-run.")
        case .poweredOff:
            fail("Bluetooth is OFF on this Mac. Turn it on and re-run.")
        case .unsupported:
            fail("this Mac reports Bluetooth LE unsupported.")
        default:
            log("Bluetooth state \(central.state.rawValue), waiting…")   // temporary states
        }
    }

    private func begin() {
        if advertObserver != nil {
            // Scan-only mode. Duplicates are allowed, so we see every advert
            // variant a device sends, not just the first one.
            log("Scan-only mode: listening for 20 s, connecting to nothing…")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
                central.stopScan()
                onScanOnlyFinished()
            }
            return
        }

        // Route 1: connect directly to a known aid.
        if wanted != .any, let known = KnownAids.find(side: wanted),
           let uuid = UUID(uuidString: known.id),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            log("Known \(wanted.rawValue.uppercased()) aid on record (\(known.id.prefix(8))…). Connecting directly, no scan.")
            log("  (If this hangs: is that aid switched on, nearby, and not grabbed by the Pixel?)")
            queue = [p]
            connectNext()
            return
        }

        // Route 2: scan. With withServices: nil we see every device and filter
        // ourselves, because our aids don't advertise FDF0.
        log("Scanning for \(Int(scanSeconds)) s for hearing aids…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) { [weak self] in self?.finishScan() }
    }

    // MARK: Scanning

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        if let observer = advertObserver {
            observer(p, ad, rssi.intValue)
            return
        }

        // "Service data" = small data blobs in the advert, tagged with a service UUID.
        let serviceData = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let ashaData = serviceData[ashaServiceUUID]
        let isAsha = ashaData != nil || services.contains(ashaServiceUUID)
        let isMfi = services.contains(mfiHearingUUID)
        let knownSide = KnownAids.side(of: p.identifier)
        guard isAsha || isMfi || knownSide != nil else { return }   // not one of our aids

        let advName = ad[CBAdvertisementDataLocalNameKey] as? String
        // ASHA service data (if present): byte 1 = capabilities, bit 0 = side.
        let caps: UInt8? = (ashaData?.count ?? 0) >= 2 ? Array(ashaData!)[1] : nil

        // macOS may report the same aid many times (each advert, plus "scan
        // responses", the follow-up packets that carry the name). Log each
        // aid once, but keep its name and signal strength up to date.
        if var c = candidates[p.identifier] {
            c.rssi = rssi.intValue
            if let n = advName { c.name = n }
            candidates[p.identifier] = c
            return
        }
        candidates[p.identifier] = Candidate(p: p, rssi: rssi.intValue, caps: caps,
                                             name: advName ?? p.name ?? "(no name)")
        let how = isAsha ? "ASHA advert" : isMfi ? "MFi advert" : "known aid"
        let sideInfo = knownSide.map { "known \($0.rawValue.uppercased())" }
            ?? caps.map { describeCapabilities($0) } ?? "side unknown until connected"
        log("Heard hearing aid \(p.identifier.uuidString.prefix(8))…  \(rssi) dBm  via \(how)  (\(sideInfo))")
    }

    private func finishScan() {
        central.stopScan()

        /// The side we can tell from adverts or KnownAids, without connecting.
        func sideOf(_ c: Candidate) -> Side? {
            KnownAids.side(of: c.p.identifier) ?? c.caps.map { $0 & 0x01 != 0 ? .right : .left }
        }
        // Drop candidates known to be the wrong side. Put known matches first,
        // then unknown ones, strongest signal first within each group.
        let usable = candidates.values.filter { wanted == .any || sideOf($0) == nil || sideOf($0) == wanted }
        queue = usable.sorted {
            let a = sideOf($0) == wanted, b = sideOf($1) == wanted
            return a != b ? a : $0.rssi > $1.rssi
        }.map { $0.p }

        log("Scan finished: \(candidates.count) hearing aid(s) heard, \(queue.count) worth trying for side '\(wanted.rawValue)'.")
        if queue.isEmpty {
            fail("""
                no suitable hearing aid found. Likely causes, cheapest check first:
                  1. The aids were still starting up, or their advertising window has closed. Open and close the battery doors, wait ~10 s, re-run.
                  2. The Pixel (or another device) has them. Turn its Bluetooth off.
                  3. They're too far away. Put them next to the Mac.
                  4. Run 'asha-probe scan' to see everything nearby.
                """, code: 2)
        }
        connectNext()
    }

    // MARK: Connecting

    private func connectNext() {
        connectTimeout?.cancel()
        guard !queue.isEmpty else {
            fail("tried every candidate; none was the \(wanted.rawValue.uppercased()) aid.", code: 2)
        }
        let p = queue.removeFirst()
        current = p
        log("Connecting to \"\(displayName(p))\" (\(p.identifier.uuidString.prefix(8))…)…")
        central.connect(p, options: connectOptions.isEmpty ? nil : connectOptions)

        // If the aid isn't advertising, connect() waits forever. Give up after 20 s.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.current === p, p.state != .connected else { return }
            log("No connection after 20 s. Giving up on this one.")
            self.central.cancelPeripheralConnection(p)
            self.connectNext()
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        connectTimeout?.cancel()
        log("CONNECTED.")
        onConnected(p)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("Connection failed: \(error?.localizedDescription ?? "unknown"). Trying the next candidate.")
        connectNext()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if rejecting && p === current {
            rejecting = false
            connectNext()
            return
        }
        onDisconnected(p, error)
    }

    // MARK: Called by the program using the finder

    /// Call after reading ReadOnlyProperties. Saves the aid's side in
    /// KnownAids. Returns true if this is the side we want. If not, it
    /// disconnects and moves on to the next candidate, and returns false.
    func checkSide(_ props: AshaProperties, of p: CBPeripheral) -> Bool {
        KnownAids.record(id: p.identifier, props: props, name: displayName(p))
        if wanted == .any || props.side == wanted { return true }
        log("This is the \(props.side.rawValue.uppercased()) aid, but we want \(wanted.rawValue.uppercased()). Disconnecting, trying the next one.")
        rejecting = true
        central.cancelPeripheralConnection(p)
        return false
    }

    /// EXPERIMENT: ask bluetoothd for a specific connection interval.
    /// ASHA wants 20 ms = 16 units of 1.25 ms. macOS picks 7.5–15 ms on its own,
    /// and apps get no public way to change that. These option names come from
    /// strings inside /usr/sbin/bluetoothd (macOS 26.5.2). They're undocumented and
    /// private: bluetoothd may ignore them. Its log line "Added device … to
    /// connection filter accept list with … connectionInterval min:… max:…"
    /// shows whether they took effect.
    /// connect() takes an ordinary dictionary of options. Public option keys
    /// are strings with the same names (e.g. CBConnectPeripheralOptionNotifyOnConnectionKey
    /// is the string "kCBConnectOptionNotifyOnConnection"), so private ones can
    /// be passed the same way.
    func setRequestedInterval(units: Int) {
        connectOptions["kCBConnectOptionOverrideMinCIFrames"] = units
        connectOptions["kCBConnectOptionOverrideMaxCIFrames"] = units
        log("EXPERIMENT: requesting connection interval \(units) units (\(Double(units) * 1.25) ms) via private connect options.")
    }

    /// EXPERIMENT: call the PRIVATE method -[CBCentralManager setDesiredConnectionLatency:forPeripheral:].
    /// It's not in Apple's public headers. We found it by listing CBCentralManager's methods at
    /// runtime (2026-10-06). The public CBPeripheralManager has a method with the same name,
    /// whose levels are 0 = low latency (short interval), 1 = medium, 2 = high (long interval).
    /// bluetoothd has settings LeConnectionLatency{Low,Medium,High,VeryHigh}{Min,Max}Interval,
    /// so each level probably maps to an interval range. Returns false if the method is missing.
    ///
    /// How the call works: Swift can't call an undeclared Objective-C method directly. So we
    /// look it up by name (a "selector"), fetch the C function that implements it, and call
    /// that function with the arguments every Objective-C method receives: the object (self),
    /// the selector, then the real arguments (an integer level, and the peripheral).
    @discardableResult
    func setDesiredConnectionLatency(_ level: Int, for p: CBPeripheral) -> Bool {
        let sel = NSSelectorFromString("setDesiredConnectionLatency:forPeripheral:")
        guard let method = class_getInstanceMethod(type(of: central), sel) else {
            log("EXPERIMENT: setDesiredConnectionLatency:forPeripheral: not found on this macOS.")
            return false
        }
        typealias Fn = @convention(c) (AnyObject, Selector, Int, AnyObject) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        log("EXPERIMENT: calling private setDesiredConnectionLatency(\(level)) for this aid.")
        fn(central, sel, level, p)
        return true
    }

    /// Disconnect the current aid (for a clean finish).
    func disconnect() {
        if let p = current { central.cancelPeripheralConnection(p) }
    }
}
