import AppKit
import Accelerate
import CoreAudio
import Combine

/// Detects bass attacks with overlapping FFT windows. A leading beat pulse and
/// five measured bass bands move independently, without idle animation.
final class SpectrumAnalyzer {
    static let size = 2048
    static let bandCount = 6
    static let hopSize = 512
    private let setup: vDSP_DFT_Setup?
    private var input = [Float](repeating: 0, count: size)
    private var imaginary = [Float](repeating: 0, count: size)
    private var realOutput = [Float](repeating: 0, count: size)
    private var imaginaryOutput = [Float](repeating: 0, count: size)
    private var window = [Float](repeating: 0, count: size)
    private var previousMagnitudes = [Double](repeating: 0, count: size / 2)
    private var history = [Float](repeating: 0, count: size)
    private var index = 0
    private var filled = 0
    private var hop = 0
    private var rate: Double = 0
    private var bassFloor = 0.0
    private var previousBass = 0.0
    private var pendingPeak: Double?
    private var pendingAge = 0.0
    private var refractory = 0.0
    private var levels = [Double](repeating: 0, count: bandCount)
    private var beatPresence = 0.0
    private let bandCenters: [Double] = [45, 65, 90, 120, 155, 200]
    private let bandWidths: [Double] = [32, 38, 45, 50, 60, 75]
    private let release: [Double] = [0.105, 0.125, 0.155, 0.18, 0.15, 0.115]

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }
    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }

    func feed(_ value: Float, sampleRate: Double) -> [Double]? {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000 else { return nil }
        if rate != sampleRate {
            rate = sampleRate; index = 0; filled = 0; hop = 0; bassFloor = 0; previousBass = 0
            pendingPeak = nil; pendingAge = 0; refractory = 0; beatPresence = 0
            levels = Array(repeating: 0, count: Self.bandCount)
            previousMagnitudes = Array(repeating: 0, count: Self.size / 2)
        }
        history[index] = value.isFinite ? min(4, max(-4, value)) : 0
        index = (index + 1) % Self.size; filled = min(Self.size, filled + 1); hop += 1
        guard filled == Self.size, hop >= Self.hopSize, let setup else { return nil }
        hop = 0
        for i in 0..<Self.size { input[i] = history[(index + i) % Self.size] * window[i] }
        vDSP_DFT_Execute(setup, input, imaginary, &realOutput, &imaginaryOutput)
        let dt = Double(Self.hopSize) / sampleRate
        var bassEnergy = 0.0, vocalEnergy = 0.0, flux = 0.0
        var bands = [Double](repeating: 0, count: Self.bandCount)
        for bin in 1..<(Self.size / 2) {
            let frequency = Double(bin) * sampleRate / Double(Self.size)
            let re = Double(realOutput[bin]), im = Double(imaginaryOutput[bin])
            let magnitude = sqrt(re * re + im * im)
            if frequency >= 35 && frequency <= 150 {
                // Most voice fundamentals and their formants sit above the kick's body.
                let weight = frequency <= 95 ? 1.0 : 0.3 * (150 - frequency) / 55
                bassEnergy += magnitude * magnitude * weight
                flux += max(0, magnitude - previousMagnitudes[bin]) * weight
            } else if frequency > 150 && frequency <= 3500 {
                vocalEnergy += magnitude * magnitude
            }
            if frequency >= 25 && frequency <= 275 {
                for band in 0..<Self.bandCount {
                    let weight = max(0, 1 - abs(frequency - bandCenters[band]) / bandWidths[band])
                    bands[band] += magnitude * magnitude * weight
                }
            }
            previousMagnitudes[bin] = magnitude
        }
        let bass = sqrt(bassEnergy) * 4 / Double(Self.size)
        let fluxAmplitude = flux * 4 / Double(Self.size)
        let bassShare = bassEnergy / max(0.000001, bassEnergy + vocalEnergy)
        var hit = 0.0
        refractory = max(0, refractory - dt)
        if let peak = pendingPeak {
            pendingAge += dt
            pendingPeak = max(peak, bass)
            // Confirm a falling attack so a rising/sustained vowel is not
            // treated as a drum hit.
            if bass < peak * 0.84, pendingAge <= 0.15 {
                hit = min(1, max(0, (20 * log10(max(peak, 0.000001)) + 48) / 38))
                pendingPeak = nil; refractory = 0.12
            } else if pendingAge > 0.15 {
                pendingPeak = nil
            }
        }
        if pendingPeak == nil, hit == 0, refractory == 0,
           bass > max(0.008, bassFloor * 1.45), bass > previousBass * 1.18,
           fluxAmplitude > bass * 0.22, bassShare > 0.45 {
            pendingPeak = bass; pendingAge = 0
        }
        let floorBlend = 1 - exp(-dt / 0.8)
        bassFloor += (bass - bassFloor) * floorBlend
        previousBass = bass
        beatPresence = max(hit, beatPresence * exp(-dt / 0.32))
        if beatPresence < 0.006 { beatPresence = 0 }
        levels[0] = max(hit, levels[0] * exp(-dt / release[0]))
        for i in 1..<Self.bandCount {
            // A bass hit opens the body of the waveform. Each remaining bar
            // follows its own measured band, not a scaled copy of the kick.
            let amplitude = sqrt(bands[i]) * 4 / Double(Self.size)
            let body = min(1, max(0, (20 * log10(max(0.000001, amplitude)) + 58) / 43))
            let target = beatPresence * body * 0.83
            let response = target > levels[i] ? 0.016 : release[i] * 0.48
            levels[i] += (target - levels[i]) * (1 - exp(-dt / response))
        }
        for i in 0..<Self.bandCount { if levels[i] < 0.006 { levels[i] = 0 } }
        return levels
    }
}

@MainActor final class MusicSpectrum: ObservableObject {
    @Published private(set) var levels = [Double](repeating: 0, count: SpectrumAnalyzer.bandCount)
    @Published private(set) var needsPermission = false
    private var tap: AnyObject?
    private var lastAttempt = Date.distantPast
    private var generation = 0
    var isFixture = false
    #if TOUCH_SCREENSHOT_FIXTURES
    func previewLevels(_ values: [Double]) {
        guard isFixture, values.count == SpectrumAnalyzer.bandCount else { return }
        levels = values.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
    }
    #endif
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
        tap = nil; levels = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
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
        description.name = "Touch — Yandex Music beat"
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
