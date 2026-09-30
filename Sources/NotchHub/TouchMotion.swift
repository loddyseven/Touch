import AppKit
import Combine

/// Curves and timings shared with the presentation renderer.
enum TouchMotion {
    static let openingDuration = 0.72
    static let closingDuration = 0.85
    static let formatDuration = 0.65
    static let recognitionDuration = 1.25
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func quartic(_ value: Double) -> Double { 1 - pow(1 - clamp(value), 4) }
    static func smooth(_ value: Double) -> Double { let t = clamp(value); return t * t * (3 - 2 * t) }
}

@MainActor
final class ScalarMotion: ObservableObject {
    @Published private(set) var value: Double = 0
    private var timer: Timer?
    private var revision = 0
    func set(_ target: Double, duration: Double, reduceMotion: Bool = false) {
        timer?.invalidate()
        revision += 1
        let currentRevision = revision
        guard !reduceMotion, duration > 0, abs(target - value) > 0.0001 else { value = target; return }
        let start = ProcessInfo.processInfo.systemUptime, origin = value
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.revision == currentRevision else { timer.invalidate(); return }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) / duration
                self.value = origin + (target - origin) * TouchMotion.quartic(elapsed)
                if elapsed >= 1 { timer.invalidate(); self.timer = nil; self.value = target }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor
final class NotchMotion: ObservableObject {
    @Published private(set) var geometry: Double = 0
    @Published private(set) var opacity: Double = 0
    @Published private(set) var closing = false
    private var timer: Timer?
    private var revision = 0
    func set(expanded: Bool, reduceMotion: Bool) {
        timer?.invalidate()
        revision += 1
        let currentRevision = revision
        closing = !expanded
        let target = expanded ? 1.0 : 0.0
        guard !reduceMotion else { geometry = target; opacity = target; return }
        let origin = geometry, originOpacity = opacity
        let duration = expanded ? TouchMotion.openingDuration : TouchMotion.closingDuration
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.revision == currentRevision else { timer.invalidate(); return }
                let raw = TouchMotion.clamp((ProcessInfo.processInfo.systemUptime - start) / duration)
                let eased = TouchMotion.quartic(raw)
                self.geometry = origin + (target - origin) * eased
                if expanded {
                    self.opacity = originOpacity + (1 - originOpacity) * TouchMotion.smooth((raw - 0.14) / 0.65)
                } else {
                    self.opacity = originOpacity * TouchMotion.smooth((1 - eased - 0.14) / 0.65)
                }
                if raw >= 1 { timer.invalidate(); self.timer = nil; self.geometry = target; self.opacity = target }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
