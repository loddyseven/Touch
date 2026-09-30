import Foundation

/// Opt-in local timing only; never records audio or track metadata.
/// Enable before launch with /tmp/TouchSpectrumTiming.enabled.
final class SpectrumTiming: @unchecked Sendable {
    static let shared = SpectrumTiming()
    private let enabledUntil = FileManager.default.fileExists(atPath: "/tmp/TouchSpectrumTiming.enabled")
        ? ProcessInfo.processInfo.systemUptime + 20 : 0
    var enabled: Bool { enabledUntil > 0 && ProcessInfo.processInfo.systemUptime < enabledUntil }
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]
    private var publishedAt = 0.0
    private var lastWrite = 0.0
    private var lastSampleEnd: Double?
    private let writer = DispatchQueue(label: "Touch.SpectrumTiming", qos: .utility)

    func add(_ name: String, _ value: Double) {
        guard enabled, value.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        samples[name, default: []].append(value)
        if samples[name]!.count > 400 { samples[name]!.removeFirst() }
    }
    func published() {
        guard enabled else { return }
        lock.lock(); publishedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    func input(sampleTime: Double, frames: Int) {
        guard enabled else { return }
        lock.lock()
        let previous = lastSampleEnd
        lastSampleEnd = sampleTime + Double(frames)
        lock.unlock()
        if let previous { add("input_gap_frames", sampleTime - previous) }
    }
    func viewUpdated() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); let publication = publishedAt; lock.unlock()
        if publication > 0 { add("view_update_ms", (now - publication) * 1000) }
        lock.lock()
        guard now - lastWrite > 1 else { lock.unlock(); return }
        lastWrite = now
        var result: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "test"]
        for (name, values) in samples where !values.isEmpty {
            result[name] = ["mean": values.reduce(0, +) / Double(values.count), "max": values.max()!, "min": values.min()!, "count": Double(values.count)]
        }
        lock.unlock()
        let report = result
        writer.async {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/Touch-spectrum-timing.json"), options: .atomic)
            }
        }
    }
}
