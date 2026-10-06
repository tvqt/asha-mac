// main.swift (ashactl) — control the background ASHA service.
//   ashactl on      streaming on (the aids play the Mac's audio whenever something is playing)
//   ashactl off     streaming off (aids stay connected; Mac speakers back to normal)
//   ashactl status  show each aid's state, volume and whether audio is flowing
//   ashactl quit    stop the service (launchd restarts it at next login, or immediately if KeepAlive)
// Commands travel as a "distributed notification" (a system-wide broadcast); the service
// answers by rewriting ~/.config/asha-mac/status.json, which `status` then reads.

import Foundation

let cmd = CommandLine.arguments.dropFirst().first ?? "status"
guard ["on", "off", "status", "quit"].contains(cmd) else {
    print("Usage: ashactl on|off|status|quit"); exit(64)
}
let statusURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/asha-mac/status.json")
let before = (try? FileManager.default.attributesOfItem(atPath: statusURL.path)[.modificationDate]) as? Date
DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.asha.command"), object: cmd,
                                                             userInfo: nil, deliverImmediately: true)
// Wait (up to 2 s) for the service to rewrite its status file.
let deadline = Date().addingTimeInterval(2)
var fresh = false
while Date() < deadline {
    let now = (try? FileManager.default.attributesOfItem(atPath: statusURL.path)[.modificationDate]) as? Date
    if let now, now != before { fresh = true; break }
    Thread.sleep(forTimeInterval: 0.05)
}
if cmd == "quit" { print(fresh ? "Service is stopping." : "No answer: the service may not be running."); exit(0) }
guard fresh, let data = try? Data(contentsOf: statusURL),
      let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    print("No answer from asha-service. Is it running? (launchctl list | grep asha, or ~/Library/Logs/asha-service.log)")
    exit(1)
}
let aids = st["aids"] as? [String: [String: Any]] ?? [:]
let vol = st["volume"] as? Int ?? 0
print("Streaming switch: \(st["enabled"] as? Bool == true ? "ON" : "OFF")   audio flowing: \(st["streaming"] as? Bool == true ? "yes" : "no")")
print("Volume (from Mac volume keys): \(vol == -128 ? "muted" : "\(vol)")   top of slider: \(st["maxVolume"] ?? "?")")
for side in ["left", "right"] {
    let a = aids[side] ?? [:]
    let b = a["battery"] as? Int ?? -1
    print("  \(side.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)) \(a["state"] ?? "?")   battery \(b >= 0 ? "\(b)%" : "?")   sent \(a["sent"] ?? 0), dropped \(a["dropped"] ?? 0)")
}
