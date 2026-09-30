import Foundation
import CoreAudio
import Combine

@MainActor
final class AudioController: ObservableObject {
    @Published var volume: Double = 0
    @Published private(set) var available = false
    @Published private(set) var muted = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    private var device: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func volumeAddress(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var writable = DarwinBoolean(false)
            if AudioObjectHasProperty(device, &address),
               AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue {
                return address
            }
        }
        return nil
    }

    func refresh() {
        guard let device, var address = volumeAddress(device) else { available = false; return }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        available = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        if available { volume = Double(value) }
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var flag: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        muted = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &flag) == noErr && flag != 0
    }

    func setVolume(_ value: Double) {
        guard let device, var address = volumeAddress(device) else { return }
        var scalar = Float32(min(1, max(0, value)))
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr {
            volume = Double(scalar)
            // Devices exposing per-channel volume need both channels updated.
            if address.mElement == 1 {
                address.mElement = 2
                if AudioObjectHasProperty(device, &address) {
                    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
                }
            }
        }
    }

    func toggleMute() {
        guard let device else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 0 : 1
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            muted = value != 0
        }
    }
}
