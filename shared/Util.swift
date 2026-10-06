// Util.swift — small helpers shared by every tool in this project.
//
// "Shared" means build.sh compiles this file into each program (probe, tone…).
// Swift lets several files form one program. Only the file named main.swift
// may contain top-level statements that run at start-up. The other files,
// like this one, just define functions, types and constants.

import Foundation

/// The moment the program started. Every log line shows seconds since this
/// moment, so our output can be lined up with macOS's Bluetooth log.
/// (A global `let` in a non-main file is created the first time it's used.
/// log() uses it right at start-up, so that's effectively program start.)
let startTime = Date()

/// Print a line prefixed with seconds since start, e.g. "[   3.21] Connected".
func log(_ message: String) {
    let t = Date().timeIntervalSince(startTime)
    print(String(format: "[%7.2f] ", t) + message)
    // Flush immediately, so lines appear in real time and nothing is lost
    // if the program exits suddenly.
    fflush(stdout)
}

/// Turn bytes into readable hex, e.g. Data([0x01, 0xAB]) -> "01 ab".
func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}
func hex(_ bytes: [UInt8]) -> String { hex(Data(bytes)) }

/// Read a little-endian 16-bit unsigned number starting at byte `offset`.
/// Little-endian = least-significant byte first, which is Bluetooth's convention:
/// bytes [0x34, 0x12] mean 0x1234.
/// `Data` may be a slice of a bigger buffer that doesn't start at index 0,
/// so we add `startIndex` instead of assuming 0.
func le16(_ data: Data, _ offset: Int) -> UInt16 {
    let i = data.startIndex + offset
    return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
}

/// Which hearing aid the user wants.
enum Side: String {
    case left, right, any
}

/// Stop the program with a message. `Never` tells Swift this function never
/// returns, so code after a call to it doesn't need a return value.
func fail(_ message: String, code: Int32 = 1) -> Never {
    log("ERROR: " + message)
    exit(code)
}
