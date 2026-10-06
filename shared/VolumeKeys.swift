// VolumeKeys.swift — follow the Mac's volume slider/keys and turn it into ASHA volume.
//
// The volume keys change the volume of the Mac's current default OUTPUT device
// (e.g. the built-in speakers). Our capture tap grabs audio BEFORE that volume is
// applied, so on its own the keys would do nothing for the aids. Instead we WATCH that
// device's volume and mute settings (Core Audio "property listeners" call us when they
// change) and send the matching value to the aids' Volume characteristic.
//
// Mapping (ASHA volume: -128 = mute, -127 = quietest, 0 = loudest; 0.375 dB per step):
//   Mac muted, or slider at 0  -> -128 (mute)
//   slider s in (0, 1]         -> maxVolume - (1 - s) × (maxVolume + 127), rounded
// so the top of the Mac's slider = `maxVolume` (default 0, the aid's full level; --max-volume caps it) and the
// bottom of the slider = -127. Core Audio's "scalar" volume is already shaped to sound even
// across the slider, so a straight-line mapping onto ASHA's dB steps feels natural.

import Foundation
import CoreAudio

final class VolumeKeys {
    let maxVolume: Int8
    /// Called on the main thread with the new ASHA volume whenever the Mac's volume or mute changes.
    var onChange: (Int8) -> Void = { _ in }

    private var device = AudioObjectID(kAudioObjectUnknown)
    private let queue = DispatchQueue.main
    private var lastSent: Int8?

    init(maxVolume: Int8) { self.maxVolume = min(max(maxVolume, -127), Safety.maxVolume) }

    /// Start watching. Also follows changes of the default output device (e.g. plugging in headphones).
    func start() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.attach()
        }
        attach()
    }

    /// The ASHA volume matching the Mac's current setting.
    var current: Int8 {
        if isMuted() { return -128 }
        guard let s = scalar() else { return maxVolume }      // device has no volume control: use the top
        if s <= 0.001 { return -128 }
        let span = Double(Int(maxVolume) + 127)
        return Int8((Double(maxVolume) - (1 - Double(s)) * span).rounded())
    }

    // MARK: Private

    private func attach() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return }
        device = id
        // Listen to volume and mute on the master element and on channels 1 and 2. Built-in
        // speakers often only have per-channel volume, so listening to all three covers both cases.
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for el in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
                var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
                if AudioObjectHasProperty(id, &a) {
                    AudioObjectAddPropertyListenerBlock(id, &a, queue) { [weak self] _, _ in self?.changed() }
                }
            }
        }
        changed()
    }

    private func changed() {
        let v = current
        guard v != lastSent else { return }
        lastSent = v
        onChange(v)
    }

    /// Volume 0…1 from the master element, or the average of channels 1 and 2.
    private func scalar() -> Float32? {
        func read(_ el: UInt32) -> Float32? {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            guard AudioObjectHasProperty(device, &a) else { return nil }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        if let m = read(kAudioObjectPropertyElementMain) { return m }
        let chans = [read(1), read(2)].compactMap { $0 }
        return chans.isEmpty ? nil : chans.reduce(0, +) / Float32(chans.count)
    }

    private func isMuted() -> Bool {
        for el in [kAudioObjectPropertyElementMain, 1] as [UInt32] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            guard AudioObjectHasProperty(device, &a) else { continue }
            var m: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m) == noErr { return m != 0 }
        }
        return false
    }
}
