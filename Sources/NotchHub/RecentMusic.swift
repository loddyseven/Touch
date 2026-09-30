import AppKit

struct RecentMusicTrack: Identifiable {
    let id: String
    var title: String
    var artist: String
    var duration: Double
    var artwork: NSImage?
    var albumID: String?
    var trackID: String?

    var albumURL: URL? {
        guard let albumID, !albumID.isEmpty, albumID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "yandexmusic://album/\(albumID)")
    }

    static func identity(title: String, artist: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{1f}" +
            artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matchesSearchResult(_ snapshot: MusicSnapshot) -> Bool {
        guard agrees(with: snapshot) else { return false }
        if let expected = trackID, let actual = snapshot.trackID, expected != actual { return false }
        let exactID = trackID != nil && trackID == snapshot.trackID
        if !exactID, let expected = albumID, let actual = snapshot.albumID, expected != actual { return false }
        // Electron sometimes omits the query from AXURL. A complete title/artist/
        // duration tuple still identifies the result without opening its link.
        return exactID || duration <= 0 || snapshot.duration > 0
    }

    static func accessibilityDuration(_ label: String) -> Double? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let clock = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if (2...3).contains(clock.count), clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let values = clock.compactMap { Double($0) }
            if values.count == clock.count, values.dropFirst().allSatisfy({ $0 < 60 }) {
                return values.reduce(0) { $0 * 60 + $1 }
            }
        }
        let regex = try! NSRegularExpression(pattern: #"(\d+)\s*(час\w*|минут\w*|секунд\w*|hours?|minutes?|seconds?)"#, options: .caseInsensitive)
        let text = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { sum, match in
            let amount = Double(text.substring(with: match.range(at: 1))) ?? 0
            let unit = text.substring(with: match.range(at: 2)).lowercased()
            let multiplier: Double = unit.hasPrefix("час") || unit.hasPrefix("hour") ? 3600 : unit.hasPrefix("минут") || unit.hasPrefix("minute") ? 60 : 1
            return sum + amount * multiplier
        }
    }

    func agrees(with snapshot: MusicSnapshot) -> Bool {
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        func artists(_ text: String) -> [String] {
            text.components(separatedBy: ",").map(normalized).filter { !$0.isEmpty }.sorted()
        }
        return !snapshot.artist.isEmpty && normalized(title) == normalized(snapshot.title) &&
            artists(artist) == artists(snapshot.artist) &&
            (duration <= 0 || snapshot.duration <= 0 || abs(duration - snapshot.duration) < 2)
    }
}

/// The three most recent player tracks for this run. No listening data is written to disk.
struct RecentMusic {
    private(set) var tracks: [RecentMusicTrack] = []

    @discardableResult mutating func record(title: String, artist: String, duration: Double, artwork: NSImage?, albumID: String? = nil, trackID: String? = nil) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let id = RecentMusicTrack.identity(title: title, artist: artist)
        let duration = duration.isFinite ? max(0, duration) : 0
        let sameTitle = tracks.indices.filter { tracks[$0].title == title }
        // AX and MediaRemote deliver metadata in stages. An artist-less snapshot
        // enriches the same song; it must not become a second history entry.
        if artist.isEmpty && sameTitle.count > 1 { return false }
        let index = tracks.firstIndex(where: { $0.id == id }) ?? sameTitle.first(where: {
            tracks[$0].artist.isEmpty || artist.isEmpty
        })
        if let index {
            let old = tracks[index]
            let artist = artist.isEmpty ? old.artist : artist
            let id = RecentMusicTrack.identity(title: title, artist: artist)
            let cover = artwork ?? old.artwork
            let duration = duration > 0 ? duration : old.duration
            let albumID = albumID ?? old.albumID
            let trackID = trackID ?? old.trackID
            guard index != 0 || old.id != id || old.duration != duration || old.artwork !== cover || old.albumID != albumID || old.trackID != trackID else { return false }
            tracks.remove(at: index)
            tracks.insert(.init(id: id, title: title, artist: artist, duration: duration, artwork: cover, albumID: albumID, trackID: trackID), at: 0)
        } else {
            tracks.insert(.init(id: id, title: title, artist: artist, duration: duration, artwork: artwork, albumID: albumID, trackID: trackID), at: 0)
        }
        tracks = Array(tracks.prefix(3))
        return true
    }
}
