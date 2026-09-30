import AppKit
import Accelerate
import CoreAudio
import Combine

/// A bounded FFT over in-memory samples. It never writes or transmits audio.
final class SpectrumAnalyzer {
    static let size = 2048
    private let setup: vDSP_DFT_Setup?
    private var input = [Float](repeating: 0, count: size)
    private var imaginary = [Float](repeating: 0, count: size)
    private var realOutput = [Float](repeating: 0, count: size)
    private var imaginaryOutput = [Float](repeating: 0, count: size)
    private var window = [Float](repeating: 0, count: size)
    private var index = 0
    private var smooth = [Double](repeating: 0, count: 5)
    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }
    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }
    func feed(_ value: Float, sampleRate: Double) -> [Double]? {
        input[index] = value.isFinite ? value : 0; index += 1
        guard index == Self.size, let setup else { return nil }
        index = 0
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(Self.size))
        vDSP_DFT_Execute(setup, input, imaginary, &realOutput, &imaginaryOutput)
        let edges: [Double] = [45, 180, 500, 1500, 4500, 14000]
        for band in 0..<5 {
            let low = max(1, Int(edges[band] * Double(Self.size) / sampleRate))
            let high = min(Self.size / 2 - 1, Int(edges[band+1] * Double(Self.size) / sampleRate))
            var energy: Float = 0
            if high >= low {
                for bin in low...high { energy += realOutput[bin]*realOutput[bin] + imaginaryOutput[bin]*imaginaryOutput[bin] }
            }
            let amplitude = sqrt(Double(energy)) * 4 / Double(Self.size)
            let decibels = 20 * log10(max(0.000001, amplitude))
            let target = min(1, max(0, (decibels + 56) / 48))
            let speed = target > smooth[band] ? 0.76 : 0.22
            smooth[band] += (target - smooth[band]) * speed
            if smooth[band] < 0.006 { smooth[band] = 0 }
        }
        return smooth
    }
}

@MainActor final class MusicSpectrum: ObservableObject {
    @Published private(set) var levels = [Double](repeating: 0, count: 5)
    @Published private(set) var needsPermission = false
    private var tap: AnyObject?
    private var lastAttempt = Date.distantPast
    private var generation = 0
    var isFixture = false
    func start() {
        guard !isFixture, tap == nil, !needsPermission, Date().timeIntervalSince(lastAttempt) > 4 else { return }
        guard #available(macOS 14.2, *) else { return }
        lastAttempt = Date()
        guard !YandexAudioTap.processes().isEmpty else { return }
        let current = generation
        do {
            tap = try YandexAudioTap { [weak self] values in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.levels = values
                }
            }
        } catch {
            needsPermission = true
        }
    }
    func stop() {
        generation += 1
        if #available(macOS 14.2, *), let tap = tap as? YandexAudioTap { tap.stop() }
        tap = nil; levels = Array(repeating: 0, count: 5)
    }
    func retry() { needsPermission = false; lastAttempt = .distantPast; start() }
}

@available(macOS 14.2, *)
private final class YandexAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Touch.YandexSpectrum", qos: .userInteractive)
    private let analyzer = SpectrumAnalyzer()
    private var stopped = false
    struct Failure: Error { let code: OSStatus }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func processes() -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyProcessObjectList), bytes: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &bytes, &ids) == noErr else { return [] }
        return ids.filter { id in
            var key = address(kAudioProcessPropertyBundleID), name: Unmanaged<CFString>? = nil
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &key, 0, nil, &size, &name) == noErr, let name else { return false }
            let bundle = (name.takeRetainedValue() as String).lowercased()
            // Include only Yandex Music and its Electron audio helper processes.
            return bundle == "ru.yandex.desktop.music" || bundle.hasPrefix("ru.yandex.desktop.music.")
        }
    }
    init(received: @escaping ([Double]) -> Void) throws {
        let ids = Self.processes()
        guard !ids.isEmpty else { throw Failure(code: kAudioHardwareBadObjectError) }
        let description = CATapDescription(stereoMixdownOfProcesses: ids)
        description.name = "Touch — Yandex Music spectrum"
        description.isPrivate = true; description.muteBehavior = .unmuted
        if #available(macOS 26.0, *) { description.isProcessRestoreEnabled = true }
        var result = AudioHardwareCreateProcessTap(description, &tapID)
        guard result == noErr else { throw Failure(code: result) }
        do {
            var format = AudioStreamBasicDescription(), key = Self.address(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            result = AudioObjectGetPropertyData(tapID, &key, 0, nil, &size, &format)
            guard result == noErr, format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { throw Failure(code: result) }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Touch Music Visualization",
                kAudioAggregateDeviceUIDKey: "local.notchhub.spectrum.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            result = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
            guard result == noErr else { throw Failure(code: result) }
            let sampleRate = format.mSampleRate
            let analyzer = self.analyzer
            result = AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let buffer = buffers.first, let bytes = buffer.mData else { return }
                let channels = max(1, Int(buffer.mNumberChannels))
                let samples = bytes.assumingMemoryBound(to: Float.self)
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                var newest: [Double]?
                for frame in 0..<frames {
                    // Taking one channel avoids stereo phase cancellation.
                    if let values = analyzer.feed(samples[frame * channels], sampleRate: sampleRate) { newest = values }
                }
                if let newest { received(newest) }
            }
            guard result == noErr, let ioProc else { throw Failure(code: result) }
            result = AudioDeviceStart(deviceID, ioProc)
            guard result == noErr else { throw Failure(code: result) }
        } catch { stop(); throw error }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        if let ioProc { AudioDeviceStop(deviceID, ioProc); AudioDeviceDestroyIOProcID(deviceID, ioProc) }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil; deviceID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }
    deinit { stop() }
}
