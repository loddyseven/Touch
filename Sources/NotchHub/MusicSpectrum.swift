import AppKit
import Accelerate
import CoreAudio
import Combine

/// A continuous spectrum preserves melody and quiet details. Percussion adds
/// accents while the vocal midrange is weighted more gently.
final class SpectrumAnalyzer {
    static let size = 1024
    static let bandCount = 6
    private var hopSize = 256
    private var fftSize = size
    private var setup: vDSP_DFT_Setup?
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
    private var refractory = 0.0
    private var levels = [Double](repeating: 0, count: bandCount)
    private var displayLevels = [Double](repeating: 0, count: bandCount)
    // Bass, low mids, voice/body, upper mids, presence, and treble. Each FFT
    // bin belongs to one range instead of driving overlapping bass bars.
    private let bandEdges: [Double] = [25, 130, 350, 1000, 3000, 7000, 16000]
    private var binBands = [Int](repeating: -1, count: size / 2)
    private var bandAccents = [Double](repeating: 0, count: bandCount)
    private var percussionFloor = [Double](repeating: 0, count: 2)
    private var previousPercussion = [Double](repeating: 0, count: 2)
    private var percussionCooldown = [Double](repeating: 0, count: 2)
    private var percussionAttack = [Double](repeating: 0, count: 2)
    private var previousBands = [Double](repeating: 0, count: bandCount)
    private let musicWeight: [Double] = [0.60, 0.48, 0.42, 0.42, 0.50, 0.70]
    // Higher ranges carry much less energy than bass in a mixed track. Keep
    // separate sensitivity curves so quiet notes do not collapse into 1px.
    private let sensitivity: [Double] = [0.08, 0.016, 0.012, 0.009, 0.006, 0.0035]
    private(set) var beatStrength = 0.0
    private let release: [Double] = [0.06, 0.055, 0.075, 0.08, 0.07, 0.045]

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }
    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }

    func feed(_ value: Float, sampleRate: Double) -> [Double]? {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000 else { return nil }
        if rate != sampleRate {
            // Keep the analysis window near 20ms at both 44/48kHz and 88/96kHz.
            var count = 256
            while Double(count) / sampleRate < 0.018 { count *= 2 }
            if count != fftSize {
                if let setup { vDSP_DFT_DestroySetup(setup) }
                fftSize = count; hopSize = count / 4
                setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD)
                input = Array(repeating: 0, count: count)
                imaginary = Array(repeating: 0, count: count)
                realOutput = Array(repeating: 0, count: count)
                imaginaryOutput = Array(repeating: 0, count: count)
                window = Array(repeating: 0, count: count)
                history = Array(repeating: 0, count: count)
                vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
            }
            percussionFloor = Array(repeating: 0, count: 2)
            previousPercussion = Array(repeating: 0, count: 2)
            percussionCooldown = Array(repeating: 0, count: 2)
            percussionAttack = Array(repeating: 0, count: 2)
            previousBands = Array(repeating: 0, count: Self.bandCount)
            bandAccents = Array(repeating: 0, count: Self.bandCount)
            beatStrength = 0
            rate = sampleRate; index = 0; filled = 0; hop = 0; bassFloor = 0; previousBass = 0
            refractory = 0
            levels = Array(repeating: 0, count: Self.bandCount)
            displayLevels = Array(repeating: 0, count: Self.bandCount)
            previousMagnitudes = Array(repeating: 0, count: fftSize / 2)
            binBands = (0..<(fftSize / 2)).map { bin in
                let frequency = Double(bin) * sampleRate / Double(fftSize)
                return (0..<Self.bandCount).first(where: { frequency >= bandEdges[$0] && frequency < bandEdges[$0 + 1] }) ?? -1
            }
        }
        history[index] = value.isFinite ? min(4, max(-4, value)) : 0
        index = (index + 1) % fftSize; filled = min(fftSize, filled + 1); hop += 1
        guard filled == fftSize, hop >= hopSize, let setup else { return nil }
        hop = 0
        for i in 0..<fftSize { input[i] = history[(index + i) % fftSize] * window[i] }
        vDSP_DFT_Execute(setup, input, imaginary, &realOutput, &imaginaryOutput)
        let dt = Double(hopSize) / sampleRate
        var bassEnergy = 0.0, vocalEnergy = 0.0, flux = 0.0
        var bands = [Double](repeating: 0, count: Self.bandCount)
        var bandFlux = [Double](repeating: 0, count: Self.bandCount)
        var noiseEnergy = [Double](repeating: 0, count: 2)
        var noiseFlux = [Double](repeating: 0, count: 2)
        var noiseLogEnergy = [Double](repeating: 0, count: 2)
        var noiseBins = [Double](repeating: 0, count: 2)
        for bin in 1..<(fftSize / 2) {
            let frequency = Double(bin) * sampleRate / Double(fftSize)
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
            if frequency >= 350 && frequency <= 14000 {
                let zone = frequency < 2500 ? 0 : 1
                let power = magnitude * magnitude
                let previous = previousMagnitudes[bin]
                noiseEnergy[zone] += power
                noiseFlux[zone] += max(0, power - previous * previous)
                noiseLogEnergy[zone] += log(max(1e-12, power))
                noiseBins[zone] += 1
            }
            let band = binBands[bin]
            if band >= 0 {
                let power = magnitude * magnitude
                let previous = previousMagnitudes[bin]
                // The short FFT spreads low bass into its neighbouring bin.
                // Taper that edge before increasing low-mid sensitivity.
                let edge = band == 1 ? min(1, (frequency - bandEdges[1]) / 90) : 1
                let weight = edge * edge * edge
                bands[band] += power * weight
                bandFlux[band] += max(0, power - previous * previous) * weight
            }
            previousMagnitudes[bin] = magnitude
        }
        let bass = sqrt(bassEnergy) * 4 / Double(fftSize)
        let fluxAmplitude = flux * 4 / Double(fftSize)
        let bassShare = bassEnergy / max(0.000001, bassEnergy + vocalEnergy)
        var hit = 0.0
        var bassHit = 0.0
        var percussionHits = [Double](repeating: 0, count: 2)
        refractory = max(0, refractory - dt)
        // React to the rising edge. Waiting for a fall moves the visible
        // accent behind the sound, especially on long bass notes.
        if refractory == 0,
           bass > max(0.008, bassFloor * 1.45), bass > previousBass * 1.18,
           fluxAmplitude > bass * 0.22, bassShare > 0.45 {
            hit = min(1, max(0, (20 * log10(max(bass, 0.000001)) + 48) / 38))
            bassHit = hit
            refractory = 0.12
        }
        for zone in 0..<2 {
            percussionCooldown[zone] = max(0, percussionCooldown[zone] - dt)
            let amplitude = sqrt(noiseEnergy[zone]) * 4 / Double(fftSize)
            let bins = max(1, noiseBins[zone])
            // Noisy, abrupt attacks distinguish snares/claps/hats from the
            // narrow harmonic peaks of vowels. This is not vocal separation.
            let flatness = exp(noiseLogEnergy[zone] / bins) / max(1e-12, noiseEnergy[zone] / bins)
            let novelty = noiseFlux[zone] / max(1e-12, noiseEnergy[zone])
            let strength = min(1, max(0, (20 * log10(max(amplitude, 0.000001)) + 56) / 42))
            if percussionCooldown[zone] == 0, amplitude > max(0.006, percussionFloor[zone] * 2.1),
               amplitude > previousPercussion[zone] * 1.35, novelty > 0.55, flatness > 0.24 {
                hit = max(hit, strength)
                percussionHits[zone] = strength
                percussionCooldown[zone] = 0.075
                percussionAttack[zone] = 0.012
            } else if percussionAttack[zone] > 0, flatness > 0.24 {
                // Refine the same attack as the short window fills, without
                // delaying its first frame or treating it as another beat.
                hit = max(hit, strength)
                percussionHits[zone] = strength
            }
            percussionAttack[zone] = max(0, percussionAttack[zone] - dt)
            percussionFloor[zone] += (amplitude - percussionFloor[zone]) * (1 - exp(-dt / 0.35))
            previousPercussion[zone] = amplitude
        }
        let floorBlend = 1 - exp(-dt / 0.8)
        bassFloor += (bass - bassFloor) * floorBlend
        previousBass = bass
        beatStrength = hit
        for i in 0..<Self.bandCount {
            let measured = sqrt(bands[i]) * 4 / Double(fftSize)
            let amplitude = i == 0 ? measured : max(0, measured - 0.0003)
            // Continuous voice and melody remain visible independently of
            // percussion. Never multiply every band by one shared beat envelope.
            let musicalBody = amplitude / (amplitude + sensitivity[i])
            let rise = max(0, amplitude - previousBands[i]) / max(i == 0 ? 0.008 : 0.001, amplitude)
            let accentLimit = i == 1 ? 0.06 : ((2...4).contains(i) ? 0.08 : 0.16)
            let noteAccent = min(accentLimit, rise * musicalBody * (i == 0 ? 0.22 : 0.32))
            let percussion: Double
            switch i {
            case 2: percussion = percussionHits[0]
            case 3: percussion = max(percussionHits[0], percussionHits[1])
            case 4, 5: percussion = percussionHits[1]
            default: percussion = 0
            }
            // A drum may span several ranges, but each range needs its own
            // rising energy. A kick cannot lift a held melody or a silent bar.
            let novelty = min(1, bandFlux[i] / max(1e-12, bands[i]))
            let accent = i == 0 ? bassHit : percussion * novelty * sqrt(musicalBody)
            bandAccents[i] = max(accent, bandAccents[i] * exp(-dt / 0.075))
            let target = max(bandAccents[i], musicalBody * musicWeight[i] + noteAccent)
            previousBands[i] = amplitude
            // Attack immediately. Only the falling edge needs smoothing.
            if target >= levels[i] { levels[i] = target }
            else { levels[i] += (target - levels[i]) * (1 - exp(-dt / (release[i] * 0.48))) }
        }
        for i in 0..<Self.bandCount {
            if levels[i] < 0.006 { levels[i] = 0 }
            // Round abrupt height changes without delaying beat detection or
            // buffering frames. Rise quickly; let small downward steps settle.
            let smoothing = levels[i] > displayLevels[i] ? 0.008 : 0.022
            displayLevels[i] += (levels[i] - displayLevels[i]) * (1 - exp(-dt / smoothing))
            if displayLevels[i] < 0.006, levels[i] == 0 { displayLevels[i] = 0 }
        }
        return displayLevels
    }
}

/// Coalesces audio callbacks while the main thread is busy. Once it is ready,
/// display the newest measurement instead of replaying a backlog of old beats.
final class LatestSpectrumFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Double]?
    private var scheduled = false
    private var offeredAt = 0.0

    func offer(_ values: [Double]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending = values
        if SpectrumTiming.shared.enabled { offeredAt = ProcessInfo.processInfo.systemUptime }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        let values = pending
        if values != nil, SpectrumTiming.shared.enabled {
            SpectrumTiming.shared.add("main_handoff_ms", (ProcessInfo.processInfo.systemUptime - offeredAt) * 1000)
        }
        pending = nil; scheduled = false
        return values
    }
}

/// Analyze both channels independently so panned drums are kept and opposite
/// stereo phase cannot cancel the beat before it reaches the FFT.
final class StereoSpectrumAnalyzer {
    private let left = SpectrumAnalyzer()
    private let right = SpectrumAnalyzer()
    private(set) var beatStrength = 0.0

    func feed(left leftSample: Float, right rightSample: Float?, sampleRate: Double) -> [Double]? {
        let leftLevels = left.feed(leftSample, sampleRate: sampleRate)
        let rightLevels = right.feed(rightSample ?? 0, sampleRate: sampleRate)
        guard let leftLevels, let rightLevels else { return nil }
        beatStrength = max(left.beatStrength, right.beatStrength)
        return zip(leftLevels, rightLevels).map { max($0, $1) }
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
        let latest = LatestSpectrumFrame()
        do {
            tap = try YandexAudioTap { [weak self] values in
                guard latest.offer(values) else { return }
                Task { @MainActor in
                    guard let values = latest.take(), let self, self.generation == current else { return }
                    SpectrumTiming.shared.published()
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
    private let analyzer = StereoSpectrumAnalyzer()
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
            configureBuffer()
            let sampleRate = format.mSampleRate
            let analyzer = self.analyzer
            let timing = SpectrumTiming.shared
            result = AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, input, inputTime, _, _ in
                let began = timing.enabled ? ProcessInfo.processInfo.systemUptime : 0
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let buffer = buffers.first, let bytes = buffer.mData else { return }
                let channels = max(1, Int(buffer.mNumberChannels))
                let samples = bytes.assumingMemoryBound(to: Float.self)
                var frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                var rightSamples: UnsafeMutablePointer<Float>?
                var rightStride = channels
                if channels > 1 { rightSamples = samples.advanced(by: 1) }
                else if buffers.count > 1, let rightBytes = buffers[1].mData {
                    rightStride = max(1, Int(buffers[1].mNumberChannels))
                    rightSamples = rightBytes.assumingMemoryBound(to: Float.self)
                    frames = min(frames, Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size / rightStride)
                }
                var newest: [Double]?
                for frame in 0..<frames {
                    if let values = analyzer.feed(left: samples[frame * channels],
                                                  right: rightSamples?[frame * rightStride],
                                                  sampleRate: sampleRate) { newest = values }
                }
                if timing.enabled {
                    if inputTime.pointee.mFlags.contains(.sampleTimeValid) {
                        timing.input(sampleTime: inputTime.pointee.mSampleTime, frames: frames)
                    }
                    timing.add("buffer_ms", Double(frames) / sampleRate * 1000)
                    timing.add("dsp_ms", (ProcessInfo.processInfo.systemUptime - began) * 1000)
                    if inputTime.pointee.mFlags.contains(.hostTimeValid) {
                        let source = Double(AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)) / 1e9
                        timing.add("audio_age_ms", (began - source - Double(frames) / sampleRate) * 1000)
                    }
                }
                if let newest { received(newest) }
            }
            guard result == noErr, let ioProc else { throw Failure(code: result) }
            result = AudioDeviceStart(deviceID, ioProc)
            guard result == noErr else { throw Failure(code: result) }
        } catch { stop(); throw error }
    }

    private func configureBuffer() {
        // Only Touch's private tap device is changed; leave the user's output
        // device alone. Unsupported buffer sizes keep Core Audio's default.
        var key = Self.address(kAudioDevicePropertyBufferFrameSize)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &key, &settable) == noErr, settable.boolValue else { return }
        var rangeKey = Self.address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange(), size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &rangeKey, 0, nil, &size, &range) == noErr,
              range.mMinimum.isFinite, range.mMaximum.isFinite,
              range.mMinimum >= 1, range.mMaximum >= range.mMinimum,
              range.mMaximum <= Double(UInt32.max) else { return }
        var frames = UInt32(min(range.mMaximum, max(range.mMinimum, 128)))
        _ = AudioObjectSetPropertyData(deviceID, &key, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
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
