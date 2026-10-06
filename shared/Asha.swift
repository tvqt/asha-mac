// Asha.swift — ASHA protocol constants and decoders, shared by all tools.
//
// Every value here was checked (2026-10-06) against three sources:
//   1. Google's ASHA spec: source.android.com/docs/core/connect/bluetooth/asha
//   2. Android's own implementation: AOSP packages/modules/Bluetooth,
//      system/bta/hearing_aid/hearing_aid.cc (what the Pixel runs)
//   3. github.com/thewierdnut/asha_pipewire_sink, asha/Side.cxx + Side.hh
// See docs/FINDINGS.md, "Verified protocol facts".

import Foundation
import CoreBluetooth

// MARK: - GATT UUIDs
// GATT = BLE's system of named values ("characteristics") grouped into
// "services", each identified by a UUID (unique ID).

/// The ASHA service (a 16-bit UUID assigned to Google).
let ashaServiceUUID = CBUUID(string: "FDF0")

/// The five ASHA characteristics.
let readOnlyPropsUUID = CBUUID(string: "6333651e-c481-4a3e-9169-7c902aad37bb") // read: device info
let audioControlUUID  = CBUUID(string: "f0d4de7e-4a88-476c-9d9f-1937b0996cc0") // write: start/stop/status commands
let audioStatusUUID   = CBUUID(string: "38663f1a-e711-4cac-b641-326b56404837") // read+notify: command results
let volumeUUID        = CBUUID(string: "00e4ca9e-ab14-41e4-8823-f9e70c7e91df") // write: stream volume
let psmUUID           = CBUUID(string: "2d410339-82b6-42aa-b34e-e2e01df8cc1a") // read: L2CAP "port" for audio

/// The service our Oticon aids actually advertise (seen 2026-10-06). It's
/// probably Apple's "Made for iPhone" (MFi) hearing-aid service. The aids
/// don't advertise FDF0, so we use this one to spot unpaired aids.
let mfiHearingUUID = CBUUID(string: "7D74F4BD-C74A-4431-862C-CCE884371592")

/// Battery level, inside the MFi service (names and scaling from asha_pipewire_sink, Side.cxx):
///   BATTERY_100 = percent 0-100; BATTERY_10 = level 0-10 (×10 = percent). Our Oticon Real aids have only BATTERY_10.
let battery100UUID = CBUUID(string: "60fb6208-9b02-468e-aba8-b702dd6f543a")
let battery10UUID  = CBUUID(string: "24e1dff3-ae90-41bf-bfbd-2cf8df42bf87")

/// Standard Device Information service and three text characteristics.
let deviceInfoServiceUUID = CBUUID(string: "180A")
let manufacturerUUID      = CBUUID(string: "2A29")
let modelUUID             = CBUUID(string: "2A24")
let firmwareUUID          = CBUUID(string: "2A26")

/// Human-readable names for the UUIDs we know, for printing.
let knownNames: [CBUUID: String] = [
    ashaServiceUUID: "ASHA service",
    readOnlyPropsUUID: "ASHA ReadOnlyProperties",
    audioControlUUID: "ASHA AudioControlPoint",
    audioStatusUUID: "ASHA AudioStatus",
    volumeUUID: "ASHA Volume",
    psmUUID: "ASHA LE_PSM_OUT",
    mfiHearingUUID: "Apple MFi hearing-aid service (probably)",
    deviceInfoServiceUUID: "Device Information",
    manufacturerUUID: "Manufacturer Name",
    modelUUID: "Model Number",
    firmwareUUID: "Firmware Revision",
]

/// Name for a UUID if we know it, otherwise just the UUID string.
func name(_ uuid: CBUUID) -> String {
    knownNames[uuid].map { "\($0) (\(uuid.uuidString))" } ?? uuid.uuidString
}

// MARK: - AudioControlPoint commands (byte layouts from Android's hearing_aid.cc)

enum AshaCommand {
    /// Opcodes: the first byte of every AudioControlPoint command.
    static let opStart: UInt8 = 0x01
    static let opStop: UInt8 = 0x02
    static let opStatus: UInt8 = 0x03   // Android calls it "state change"

    /// Codec ID used in the Start command. Careful: this is the codec's ID
    /// (1 = G.722 at 16 kHz), NOT the bitmask value 0x0002 from
    /// ReadOnlyProperties. In the bitmask, codec ID n is bit n, so ID 1 = 0x0002.
    static let codecG722_16k: UInt8 = 0x01

    /// Audio type in Start. Android always sends 0 ("unknown").
    static let audioTypeUnknown: UInt8 = 0x00

    /// Values for the Status command's first parameter.
    static let statusOtherDisconnected: UInt8 = 0x00
    static let statusOtherConnected: UInt8 = 0x01
    static let statusConnParamsUpdated: UInt8 = 0x02

    /// Start: [01, codec, audiotype, volume, otherstate].
    /// volume is a signed byte (-128…0). Swift stores it in a UInt8 with the
    /// same bit pattern, e.g. -127 -> 0x81. otherstate = 1 if the other aid is
    /// connected and streaming, else 0.
    static func start(volume: Int8, otherSideStreaming: Bool) -> [UInt8] {
        [opStart, codecG722_16k, audioTypeUnknown, UInt8(bitPattern: volume), otherSideStreaming ? 1 : 0]
    }

    /// Stop: just the opcode.
    static func stop() -> [UInt8] { [opStop] }

    /// "Connection parameters were updated", plus the connection interval in
    /// 1.25 ms units. Google's spec text lists only the first parameter, but
    /// Android (and asha_pipewire_sink) also send the interval byte, so we
    /// copy Android exactly.
    static func connParamsUpdated(intervalUnits: UInt8) -> [UInt8] {
        [opStatus, statusConnParamsUpdated, intervalUnits]
    }
}

/// Explain an AudioStatus value. It's a signed byte: 0 = OK, negative = error.
func describeAudioStatus(_ raw: UInt8) -> String {
    switch Int8(bitPattern: raw) {
    case 0: return "0 = OK"
    case -1: return "-1 = unknown command"
    case -2: return "-2 = illegal parameters"
    case let v: return "\(v) = unknown/other error"
    }
}

// MARK: - Audio framing

/// G.722 at 16 kHz turns 16,000 samples/s into 8,000 bytes/s, i.e. 8 bytes per ms.
/// One ASHA audio packet carries exactly one connection interval's worth of audio
/// ("An audio frame should always match the connection interval in time", spec).
///   10 ms ->  80 bytes,  15 ms -> 120 bytes,  20 ms -> 160 bytes.
/// Same formula as Android's CalcCompressedAudioPacketSize.
func g722BytesPerFrame(frameMs: Int) -> Int { frameMs * 8 }
func samplesPerFrame(frameMs: Int) -> Int { frameMs * 16 }   // 16 samples per ms at 16 kHz

// MARK: - ReadOnlyProperties

/// The aid's description of itself (17 bytes, little-endian). Layout per the spec:
///   0      Version (must be 1)
///   1      DeviceCapabilities: bit0 1=right/0=left, bit1 binaural, bit2 CSIS
///   2-9    HiSyncId (the same for both aids of a pair; first 2 bytes = manufacturer ID)
///   10     FeatureMap: bit0 = supports audio streaming over L2CAP
///   11-12  RenderDelay in ms
///   13-14  reserved
///   15-16  SupportedCodecs bitmask: bit1 = G.722 16 kHz
struct AshaProperties {
    let raw: Data
    let version: UInt8
    let capabilities: UInt8
    let hiSyncId: Data
    let featureMap: UInt8
    let renderDelayMs: UInt16
    let reserved: UInt16
    let codecs: UInt16

    var isRight: Bool { capabilities & 0x01 != 0 }
    var side: Side { isRight ? .right : .left }
    var isBinaural: Bool { capabilities & 0x02 != 0 }
    var supportsStreaming: Bool { featureMap & 0x01 != 0 }
    var supportsG722_16k: Bool { codecs & 0x0002 != 0 }

    /// Returns nil if the data is too short to be valid.
    init?(_ v: Data) {
        guard v.count >= 17 else { return nil }
        let b = Array(v)   // a plain array, indexed from 0
        raw = v
        version = b[0]
        capabilities = b[1]
        hiSyncId = Data(b[2..<10])
        featureMap = b[10]
        renderDelayMs = le16(v, 11)
        reserved = le16(v, 13)
        codecs = le16(v, 15)
    }

    /// Human-readable lines, for logging.
    func describe() -> [String] {
        [
            "ReadOnlyProperties raw (\(raw.count) bytes): \(hex(raw))",
            "  Version:            \(version)" + (version == 1 ? " (OK)" : " (UNEXPECTED, spec says 1)"),
            "  DeviceCapabilities: 0x\(String(format: "%02x", capabilities)) = \(describeCapabilities(capabilities))",
            "  HiSyncId:           \(hex(hiSyncId))  (manufacturer ID part: 0x\(String(format: "%04x", le16(hiSyncId, 0))))",
            "  FeatureMap:         0x\(String(format: "%02x", featureMap)) = "
                + (supportsStreaming ? "audio streaming supported" : "audio streaming NOT supported"),
            "  RenderDelay:        \(renderDelayMs) ms",
            "  Reserved/PrepDelay: \(reserved)",
            "  SupportedCodecs:    0x\(String(format: "%04x", codecs))"
                + (supportsG722_16k ? " = G.722 @16 kHz supported" : " (G.722 @16 kHz NOT listed!)"),
        ]
    }
}

/// Explain the capabilities byte (same bits in adverts and ReadOnlyProperties).
func describeCapabilities(_ c: UInt8) -> String {
    let side = (c & 0x01) != 0 ? "RIGHT" : "LEFT"
    let mode = (c & 0x02) != 0 ? "binaural (one of a pair)" : "monaural (single aid)"
    let csis = (c & 0x04) != 0 ? "CSIS supported" : "no CSIS"
    return "\(side), \(mode), \(csis)"
}
