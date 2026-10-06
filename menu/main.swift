// main.swift (ASHA menu-bar app) — step E: a menu-bar front end for asha-service.
//
// It never talks to the hearing aids itself. It reads the service's status file
// (~/.config/asha-mac/status.json) once a second and sends the same commands as `ashactl`
// (a "distributed notification" named local.asha.command). So the service keeps working
// whether or not this app is running.
//
// Menu:  LEFT/RIGHT state · volume · [✓] Stream to hearing aids · [✓] Use "Hearing Aids" as sound output
//        · Open log · Restart service · Quit menu
// Icon:  ear.fill = streaming, ear = connected and ready, ear with "!" = service not running / no aid connected.

import AppKit
import CoreAudio

let statusURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/asha-mac/status.json")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/asha-service.log")
let outputUID = "ASHA Hearing Aids_UID"      // the visible "Hearing Aids" output device (driver/)

/// The service's last status, or nil if it hasn't written one for a while (= not running).
func readStatus() -> [String: Any]? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: statusURL.path),
          let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 8,
          let data = try? Data(contentsOf: statusURL) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func send(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.asha.command"), object: command,
                                                                 userInfo: nil, deliverImmediately: true)
}

// MARK: Core Audio helpers: which device is the default output, and switching it

func deviceID(forUID uid: String) -> AudioObjectID? {
    var id = AudioObjectID(kAudioObjectUnknown)
    var cf = uid as CFString
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id) }
    return st == noErr && id != kAudioObjectUnknown ? id : nil
}

func defaultOutput() -> AudioObjectID {
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return id
}

func setDefaultOutput(_ id: AudioObjectID) {
    var dev = id
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
}

/// The built-in speakers (to switch back to), found by transport type "built-in" with output streams.
func builtInOutput() -> AudioObjectID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    for id in ids {
        var t: UInt32 = 0; var s = UInt32(4)
        var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &ta, 0, nil, &s, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn else { continue }
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var ss: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 { return id }
    }
    return nil
}

// MARK: The app

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self          // rebuild the menu each time it opens (menuNeedsUpdate)
        item.menu = menu
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshIcon() }
    }

    func refreshIcon() {
        let st = readStatus()
        let aids = st?["aids"] as? [String: [String: Any]] ?? [:]
        let connected = aids.values.contains { ["READY", "STARTING", "STREAMING"].contains($0["state"] as? String ?? "") }
        let symbol: String
        let tip: String
        if st == nil { symbol = "ear.trianglebadge.exclamationmark"; tip = "ASHA: service not running" }
        else if st?["streaming"] as? Bool == true { symbol = "ear.fill"; tip = "ASHA: streaming to hearing aids" }
        else if connected { symbol = "ear"; tip = "ASHA: hearing aids connected" }
        else { symbol = "ear.trianglebadge.exclamationmark"; tip = "ASHA: hearing aids not connected" }
        // If a symbol name were unknown, the image would be nil and the item invisible: fall back to text.
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            item.button?.image = img; item.button?.title = ""
        } else {
            item.button?.image = nil; item.button?.title = "ASHA"
        }
        item.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = readStatus()
        if let st {
            let aids = st["aids"] as? [String: [String: Any]] ?? [:]
            for side in ["left", "right"] {
                let state = (aids[side]?["state"] as? String ?? "?").capitalized
                let b = aids[side]?["battery"] as? Int ?? -1
                let battery = b >= 0 ? "   ·   battery \(b)%" + (b <= 20 ? " (low)" : "") : ""
                menu.addItem(info("\(side.capitalized) aid: \(state)\(battery)"))
            }
            let v = st["volume"] as? Int ?? 0
            menu.addItem(info(v == -128 ? "Volume: muted" : "Volume: \(v)  (use the volume keys)"))
            menu.addItem(.separator())
            let on = menu.addItem(withTitle: "Stream to hearing aids", action: #selector(toggleStreaming), keyEquivalent: "")
            on.target = self
            on.state = st["enabled"] as? Bool == true ? .on : .off
        } else {
            menu.addItem(info("Service not running"))
            menu.addItem(.separator())
        }
        let out = menu.addItem(withTitle: "Use \"Hearing Aids\" as sound output", action: #selector(toggleOutput), keyEquivalent: "")
        out.target = self
        if let id = deviceID(forUID: outputUID) { out.state = defaultOutput() == id ? .on : .off } else { out.isEnabled = false }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restart service", action: #selector(restartService), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func info(_ title: String) -> NSMenuItem { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }

    @objc func toggleStreaming() { send(readStatus()?["enabled"] as? Bool == true ? "off" : "on") }

    @objc func toggleOutput() {
        guard let ha = deviceID(forUID: outputUID) else { return }
        if defaultOutput() == ha { if let sp = builtInOutput() { setDefaultOutput(sp) } } else { setDefaultOutput(ha) }
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    @objc func restartService() {
        // launchctl kickstart -k: stop the LaunchAgent's process and start it again.
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/local.asha.service"]
        try? p.run()
    }
}

let app = NSApplication.shared
let delegate = MenuApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)      // menu-bar only: no Dock icon, no main window
app.run()
