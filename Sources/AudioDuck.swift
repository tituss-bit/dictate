// Silences the Mac's audio output while a take is being recorded so music, videos and
// calls don't bleed into the microphone. Restores the exact previous state on release.
// Uses the device's hardware mute when it has one, otherwise drops the volume to zero.

import CoreAudio
import AudioToolbox
import Foundation

final class AudioDucker {
    private var device: AudioDeviceID = 0
    private var savedMute: UInt32?
    private var savedVolume: Float32?
    private static let flag = "audioDucked"   // survives a crash so we can undo the mute on next launch

    private static var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static func defaultOutput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func canMute(_ dev: AudioDeviceID) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &muteAddr)
            && AudioObjectIsPropertySettable(dev, &muteAddr, &settable) == noErr && settable.boolValue
    }

    var isDucked: Bool { savedMute != nil || savedVolume != nil }

    func duck() {
        guard !isDucked else { return }
        device = Self.defaultOutput()
        guard device != 0 else { return }
        if Self.canMute(device) {
            var cur: UInt32 = 0, size = UInt32(4)
            guard AudioObjectGetPropertyData(device, &Self.muteAddr, 0, nil, &size, &cur) == noErr else { return }
            var one: UInt32 = 1
            AudioObjectSetPropertyData(device, &Self.muteAddr, 0, nil, 4, &one)
            savedMute = cur
        } else {
            var cur: Float32 = 0, size = UInt32(4)
            guard AudioObjectGetPropertyData(device, &Self.volumeAddr, 0, nil, &size, &cur) == noErr else { return }
            var zero: Float32 = 0
            AudioObjectSetPropertyData(device, &Self.volumeAddr, 0, nil, 4, &zero)
            savedVolume = cur
        }
        UserDefaults.standard.set(true, forKey: Self.flag)
    }

    func restore() {
        if var m = savedMute { AudioObjectSetPropertyData(device, &Self.muteAddr, 0, nil, 4, &m) }
        if var v = savedVolume { AudioObjectSetPropertyData(device, &Self.volumeAddr, 0, nil, 4, &v) }
        savedMute = nil; savedVolume = nil
        UserDefaults.standard.removeObject(forKey: Self.flag)
    }

    /// Previous run died mid-take (force-quit, crash): the Mac would still be muted. Undo that.
    func recoverAfterCrash() {
        guard UserDefaults.standard.bool(forKey: Self.flag) else { return }
        let dev = Self.defaultOutput()
        if Self.canMute(dev) { var zero: UInt32 = 0; AudioObjectSetPropertyData(dev, &Self.muteAddr, 0, nil, 4, &zero) }
        UserDefaults.standard.removeObject(forKey: Self.flag)
    }
}
