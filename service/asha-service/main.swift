// main.swift (asha-service) — step C: background service for both hearing aids.
// Normally started at login by launchd (see scripts/install.sh); can also be run by hand
// in a Terminal for testing. Control it with `ashactl on|off|status|quit`.
// Logs go to ~/Library/Logs/asha-service.log when run by launchd.
//
// USAGE: asha-service [--idle-seconds 30] [--max-volume 0]

import Foundation

var idle = 30.0
var maxVol: Int8 = 0
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--idle-seconds": idle = Double(args.isEmpty ? "" : args.removeFirst()) ?? 30
    case "--max-volume": maxVol = Int8(args.isEmpty ? "" : args.removeFirst()) ?? 0
    default: fail("Usage: asha-service [--idle-seconds 30] [--max-volume 0]", code: 64)
    }
}
// Only one service at a time: two would fight over the same aids. Ask `pgrep` for other copies.
let pg = Process(); pg.launchPath = "/usr/bin/pgrep"; pg.arguments = ["-x", "asha-service"]
let pipe = Pipe(); pg.standardOutput = pipe; try? pg.run(); pg.waitUntilExit()
let pids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .split(separator: "\n").compactMap { Int32($0) }.filter { $0 != ProcessInfo.processInfo.processIdentifier }
if !pids.isEmpty { fail("asha-service is already running (pid \(pids[0])). Use `ashactl quit` first.", code: 3) }

let service = AshaService(idleSeconds: idle, maxVolume: maxVol)
// Ctrl-C / Ctrl-Z / launchd's SIGTERM: stop cleanly (Stop to the aids, speakers unmuted).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGTSTP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { service.shutdown() }
    src.resume()
    signalSources.append(src)
}
service.start()
RunLoop.main.run()
