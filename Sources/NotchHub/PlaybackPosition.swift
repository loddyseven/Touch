import Foundation

enum PlaybackPosition {
    static func clamped(_ seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(duration, max(0, seconds))
    }

    static func microseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0,
              seconds < Double(Int64.max) / 1_000_000 else { return nil }
        return Int64((seconds * 1_000_000).rounded(.down))
    }
}

struct PendingPlaybackSeek {
    let target: Double
    let track: String
    let started: Date

    func position(at date: Date, playing: Bool) -> Double {
        target + (playing ? max(0, date.timeIntervalSince(started)) : 0)
    }

    func shouldHold(actual: Double, track: String, at date: Date, playing: Bool) -> Bool {
        self.track == track && date.timeIntervalSince(started) < 4 &&
            abs(actual - position(at: date, playing: playing)) > 2
    }
}
