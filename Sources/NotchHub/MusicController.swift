import AppKit
import ApplicationServices
import Combine

struct MusicSnapshot {
    var title = ""
    var artist = ""
    var playing = false
    var elapsed: Double = 0
    var duration: Double = 0
    var artworkURL: URL?
    var albumID: String?
    var trackID: String?
}

/// Reads only Yandex Music's player, after the user grants Accessibility access.
/// No account tokens or browser contents are stored. Recent tracks stay in memory only.
@MainActor
final class MusicController: ObservableObject {
    static let bundleID = "ru.yandex.desktop.music"
    @Published var title = ""
    @Published var artist = ""
    @Published var artwork: NSImage? { didSet { waveColor = ArtworkPalette.accent(artwork) } }
    @Published private(set) var waveColor = NSColor(white: 0.85, alpha: 1)
    @Published var playing = false {
        didSet { if !isFixture && playing != oldValue { playing ? spectrum.start() : spectrum.stop() } }
    }
    let spectrum = MusicSpectrum()
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    var isScrubbing = false
    @Published var connected = false
    @Published var permissionNeeded = !AXIsProcessTrusted()
    @Published var message: String?
    @Published private(set) var recentTracks: [RecentMusicTrack] = []
    @Published private(set) var liked: Bool?
    @Published private(set) var startingRecentID: String?
    private var recent = RecentMusic()
    private var currentAlbumID: String?
    private var currentTrackID: String?
    private var recentPlaybackTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var pendingHistorySignature = ""
    private var recordedHistorySignature = ""
    private var refreshingExtras = false
    var hasTrack: Bool { !title.isEmpty && connected }
    var canSeek: Bool { hasTrack && duration.isFinite && duration > 0 }
    var isFixture = false
    private let bridge = NowPlayingBridge()
    private var remoteActive = false
    private var remoteElapsed: Double = 0
    private var remoteTimestamp = Date()
    private var remoteTrack = ""
    private var remoteArtwork: String?
    private var timer: Timer?
    private var progressTimer: Timer?
    private var refreshing = false
    private var artworkKey: String?
    private var artworkTask: Task<Void, Never>?
    private var lastSuccess = Date.distantPast
    private var seekGeneration = 0
    private var pendingSeek: PendingPlaybackSeek?
    private let queue = DispatchQueue(label: "Touch.YandexPlayer", qos: .utility)
    func start() {
        guard timer == nil else { return }
        #if TOUCH_MEDIA_REMOTE
        bridge.received = { [weak self] payload in self?.applyRemote(payload) }
        bridge.disconnected = { [weak self] in self?.remoteActive = false; self?.refresh() }
        _ = bridge.start()
        #endif
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 0.4
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.remoteActive, self.playing, !self.isScrubbing else { return }
                self.updateElapsed()
            }
        }
        progressTimer?.tolerance = 0.025
    }
    func connect() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissionNeeded = !AXIsProcessTrusted()
        if permissionNeeded {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else { openPlayer(); refresh() }
    }
    func openPlayer() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else { message = "Установи приложение Яндекс Музыки для Mac" }
    }
    func refresh() {
        guard !isFixture, !refreshing else { return }
        if playing { spectrum.start() }
        if remoteActive {
            updateElapsed()
            refreshExtras()
            return
        }
        permissionNeeded = !AXIsProcessTrusted()
        guard !permissionNeeded else { connected = false; playing = false; return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            connected = false; playing = false; return
        }
        refreshing = true
        let pid = app.processIdentifier
        queue.async { [weak self] in
            let snapshot = YandexAccessibility.read(pid: pid)
            Task { @MainActor in
                guard let self else { return }; self.refreshing = false
                guard !self.remoteActive else { return }
                guard let snapshot else {
                    if Date().timeIntervalSince(self.lastSuccess) > 8 { self.connected = false; self.playing = false; self.message = "Открой окно Яндекс Музыки — жду данные плеера" }
                    return
                }
                self.lastSuccess = Date(); self.connected = true; self.message = nil
                if self.title != snapshot.title { self.artwork = nil; self.title = snapshot.title }
                if self.artist != snapshot.artist { self.artist = snapshot.artist }
                if self.playing != snapshot.playing { self.playing = snapshot.playing }
                self.duration = snapshot.duration
                self.currentAlbumID = snapshot.albumID
                self.currentTrackID = snapshot.trackID
                self.acceptPosition(snapshot.elapsed, timestamp: Date())
                self.loadArtwork(snapshot)
                self.recordCurrentTrack()
                self.refreshExtras()
            }
        }
    }
    func command(_ command: String) {
        if command == "like" { toggleLike(); return }
        guard ["toggle", "previous", "next"].contains(command) else { return }
        if remoteActive && !isFixture { bridge.send(command == "next" ? 4 : command == "previous" ? 5 : 2); return }
        guard !isFixture, AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            let success = YandexAccessibility.press(pid: pid, command: command)
            Task { @MainActor in
                if !success { self?.message = "Открой плеер Яндекс Музыки, чтобы управлять им" }
                self?.refresh()
            }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        progressTimer?.invalidate(); progressTimer = nil
        bridge.stop(); spectrum.stop()
        recentPlaybackTask?.cancel(); recentPlaybackTask = nil; startingRecentID = nil
        historyTask?.cancel(); historyTask = nil
    }
    func seek(to seconds: Double) {
        guard canSeek, let target = PlaybackPosition.clamped(seconds, duration: duration) else { return }
        if isFixture { elapsed = target; return }
        seekGeneration += 1
        let generation = seekGeneration
        let track = title + "|" + artist
        let beforeSeek = elapsed
        pendingSeek = PendingPlaybackSeek(target: target, track: track, started: Date())
        // Commit the visible position before SwiftUI releases its drag state.
        elapsed = target
        let completed: (Bool) -> Void = { [weak self] success in
            guard let self, self.seekGeneration == generation,
                  self.title + "|" + self.artist == track else { return }
            if success {
                self.message = nil
            } else {
                self.pendingSeek = nil; self.elapsed = beforeSeek
                self.message = "Не удалось перемотать трек. Открой окно Яндекс Музыки и попробуй ещё раз."
            }
        }
        if remoteActive { bridge.seek(to: target, completion: completed); return }
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            completed(false); return
        }
        let pid = app.processIdentifier
        queue.async {
            let success = YandexAccessibility.seek(pid: pid, seconds: target)
            DispatchQueue.main.async { completed(success) }
        }
    }
    private func applyRemote(_ payload: [String: Any]) {
        guard !isFixture else { return }
        guard let bundle = payload["bundleIdentifier"] as? String,
              bundle == Self.bundleID || (payload["parentApplicationBundleIdentifier"] as? String) == Self.bundleID,
              let song = payload["title"] as? String, !song.isEmpty else {
            remoteActive = false; return
        }
        remoteActive = true; permissionNeeded = false; connected = true; message = nil
        let incomingArtist = payload["artist"] as? String ?? ""
        let sameTitle = title == song
        title = song
        if !sameTitle || !incomingArtist.isEmpty { artist = incomingArtist }
        playing = payload["playing"] as? Bool ?? false
        duration = (payload["durationMicros"] as? Double ?? 0) / 1_000_000
        let incomingElapsed = (payload["elapsedTimeMicros"] as? Double ?? 0) / 1_000_000
        let incomingTimestamp = (payload["timestampEpochMicros"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        let key = song + "|" + artist + "|" + (payload["album"] as? String ?? "")
        if key != remoteTrack {
            remoteTrack = key; remoteArtwork = nil; artwork = nil; liked = nil
            currentAlbumID = nil; currentTrackID = nil
            artworkTask?.cancel(); remoteTimestamp = .distantPast
        }
        if let encoded = payload["artworkData"] as? String, encoded != remoteArtwork,
           encoded.count < 6_000_000, let data = Data(base64Encoded: encoded), let cover = NSImage(data: data) {
            remoteArtwork = encoded; artwork = cover
        }
        acceptPosition(incomingElapsed, timestamp: incomingTimestamp)
        recordCurrentTrack()
    }
    private func acceptPosition(_ seconds: Double, timestamp: Date) {
        guard seconds.isFinite else { return }
        if pendingSeek == nil && timestamp < remoteTimestamp { return }
        let now = Date()
        let actual = seconds + (playing ? max(0, now.timeIntervalSince(timestamp)) : 0)
        if let pendingSeek, pendingSeek.shouldHold(actual: actual, track: title + "|" + artist, at: now, playing: playing) {
            updateElapsed(); return
        }
        pendingSeek = nil
        remoteElapsed = seconds; remoteTimestamp = timestamp
        updateElapsed()
    }
    private func updateElapsed() {
        let now = Date()
        if let pendingSeek, now.timeIntervalSince(pendingSeek.started) < 4 {
            elapsed = min(duration, pendingSeek.position(at: now, playing: playing))
        } else {
            pendingSeek = nil
            elapsed = min(duration > 0 ? duration : .greatestFiniteMagnitude,
                          remoteElapsed + (playing ? max(0, now.timeIntervalSince(remoteTimestamp)) : 0))
        }
    }
    private func loadArtwork(_ snapshot: MusicSnapshot) {
        let key = snapshot.artworkURL?.absoluteString ?? snapshot.albumID ?? snapshot.title
        guard key != artworkKey else { return }
        artworkKey = key; artworkTask?.cancel(); artwork = nil
        artworkTask = Task {
            var url = snapshot.artworkURL
            if url == nil, let albumID = snapshot.albumID, albumID.allSatisfy(\.isNumber),
               let endpoint = URL(string: "https://api.music.yandex.net/albums/\(albumID)") {
                var request = URLRequest(url: endpoint); request.timeoutInterval = 6
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any], let cover = result["coverUri"] as? String {
                    url = URL(string: "https://" + cover.replacingOccurrences(of: "%%", with: "200x200"))
                }
            }
            guard let url, url.scheme == "https", let host = url.host,
                  host == "avatars.yandex.net" || host == "avatars.mds.yandex.net" else { return }
            var request = URLRequest(url: url); request.timeoutInterval = 6
            guard let (data, _) = try? await URLSession.shared.data(for: request), data.count < 4_000_000,
                  !Task.isCancelled, self.artworkKey == key else { return }
            self.artwork = NSImage(data: data)
            self.recordCurrentTrack()
        }
    }

    func recordCurrentTrack() {
        guard hasTrack, !artist.isEmpty else { return }
        let candidate = RecentMusicTrack(id: RecentMusicTrack.identity(title: title, artist: artist),
            title: title, artist: artist, duration: duration, artwork: artwork,
            albumID: currentAlbumID, trackID: currentTrackID)
        if isFixture { commitHistory(candidate); return }
        let signature = candidate.id + "|\(duration)|\(artwork.map { String(describing: ObjectIdentifier($0)) } ?? "")|\(currentAlbumID ?? "")|\(currentTrackID ?? "")"
        guard signature != recordedHistorySignature,
              signature != pendingHistorySignature || historyTask == nil else { return }
        pendingHistorySignature = signature
        historyGeneration += 1
        let generation = historyGeneration
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self, generation == self.historyGeneration else { return }
            defer { if generation == self.historyGeneration { self.historyTask = nil } }
            // Confirm a complete, settled tuple against the player's own UI.
            // MediaRemote can momentarily pair a new title with the old artist/cover.
            if AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
                let pid = app.processIdentifier
                let snapshot: MusicSnapshot? = await withCheckedContinuation { continuation in
                    self.queue.async { continuation.resume(returning: YandexAccessibility.read(pid: pid)) }
                }
                guard let snapshot, candidate.agrees(with: snapshot) else { return }
            }
            guard !Task.isCancelled, self.hasTrack, generation == self.historyGeneration,
                  candidate.id == RecentMusicTrack.identity(title: self.title, artist: self.artist) else { return }
            self.commitHistory(candidate)
            self.recordedHistorySignature = signature
        }
    }

    private func commitHistory(_ candidate: RecentMusicTrack) {
        if recent.record(title: candidate.title, artist: candidate.artist, duration: candidate.duration,
                         artwork: candidate.artwork, albumID: candidate.albumID, trackID: candidate.trackID) {
            recentTracks = recent.tracks
        }
    }

    private func refreshExtras() {
        guard !isFixture, !refreshingExtras, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        refreshingExtras = true
        let pid = app.processIdentifier
        let track = RecentMusicTrack.identity(title: title, artist: artist)
        queue.async { [weak self] in
            let liked = YandexAccessibility.liked(pid: pid)
            let snapshot = YandexAccessibility.read(pid: pid)
            Task { @MainActor in
                guard let self else { return }
                self.refreshingExtras = false
                guard track == RecentMusicTrack.identity(title: self.title, artist: self.artist) else { return }
                self.liked = liked
                if let snapshot, snapshot.title == self.title,
                   snapshot.artist.isEmpty || snapshot.artist == self.artist {
                    self.currentAlbumID = snapshot.albumID ?? self.currentAlbumID
                    self.currentTrackID = snapshot.trackID ?? self.currentTrackID
                    self.recordCurrentTrack()
                }
            }
        }
    }

    func playRecent(_ track: RecentMusicTrack) {
        guard !isFixture, startingRecentID == nil else { return }
        if hasTrack && track.id == RecentMusicTrack.identity(title: title, artist: artist) {
            seek(to: 0)
            if !playing { command("toggle") }
            return
        }
        guard AXIsProcessTrusted() else { permissionNeeded = true; connect(); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            message = "Яндекс Музыка закрыта"; return
        }
        let pid = app.processIdentifier
        startingRecentID = track.id; message = nil
        recentPlaybackTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startingRecentID = nil; self.recentPlaybackTask = nil }
            var searchPrepared = false
            for _ in 0..<24 {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                if !searchPrepared {
                    let prepared: Bool = await withCheckedContinuation { continuation in
                        self.queue.async { continuation.resume(returning: YandexAccessibility.prepareRecentSearch(pid: pid, track: track)) }
                    }
                    searchPrepared = prepared
                    continue
                }
                let success: Bool = await withCheckedContinuation { continuation in
                    self.queue.async {
                        continuation.resume(returning: YandexAccessibility.playRecent(pid: pid, track: track))
                    }
                }
                if success {
                    for _ in 0..<10 {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        let snapshot: MusicSnapshot? = await withCheckedContinuation { continuation in
                            self.queue.async { continuation.resume(returning: YandexAccessibility.read(pid: pid)) }
                        }
                        if let snapshot, snapshot.playing, track.agrees(with: snapshot) { self.message = nil; self.refresh(); return }
                    }
                    break
                }
            }
            self.message = "Яндекс Музыка не подтвердила запуск выбранного трека"
        }
    }

    private func toggleLike() {
        guard hasTrack, liked != nil, !isFixture, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let pid = app.processIdentifier
        let track = RecentMusicTrack.identity(title: title, artist: artist)
        queue.async { [weak self] in
            let success = YandexAccessibility.press(pid: pid, command: "like")
            Task { @MainActor in
                guard let self, track == RecentMusicTrack.identity(title: self.title, artist: self.artist) else { return }
                if !success { self.message = "Не удалось изменить отметку «Нравится». Открой окно Яндекс Музыки." }
                self.refreshExtras()
            }
        }
    }
}

private enum YandexAccessibility {
    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func label(_ e: AXUIElement) -> String {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap { value(e, $0) as? String }.first(where: { !$0.isEmpty }) ?? ""
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] { value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func descendants(_ root: AXUIElement, limit: Int = 1000) -> [AXUIElement] {
        var result: [AXUIElement] = [], pending = [root]
        while !pending.isEmpty && result.count < limit {
            let e = pending.removeLast(); result.append(e)
            pending.append(contentsOf: children(e).reversed())
        }
        return result
    }
    private static var cachedPlayer: AXUIElement?
    private static var cachedPID: pid_t = 0
    static func player(pid: pid_t) -> AXUIElement? {
        if cachedPID == pid, let cachedPlayer, value(cachedPlayer, kAXParentAttribute) != nil { return cachedPlayer }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        // Electron exposes its semantic tree lazily to assistive clients.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? children(app)
        var pending = windows, index = 0
        while index < pending.count && index < 5000 {
            let e = pending[index]; index += 1
            let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap { value(e, $0) as? String }
            if labels.contains(where: { ["Плеер", "Player"].contains($0) }) { cachedPID = pid; cachedPlayer = e; return e }
            pending.append(contentsOf: children(e))
        }
        cachedPlayer = nil; return nil
    }
    static func read(pid: pid_t) -> MusicSnapshot? {
        guard let player = player(pid: pid) else { return nil }
        let nodes = descendants(player, limit: 220)
        var result = MusicSnapshot(), texts: [String] = [], linkedArtists: [String] = []
        for e in nodes {
            let text = label(e), role = value(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole && ["Пауза", "Pause"].contains(text) { result.playing = true }
            if role == kAXStaticTextRole && !text.isEmpty && !texts.contains(text) { texts.append(text) }
            if role == "AXLink" {
                if text.hasPrefix("Трек ") { result.title = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) }
                if text.hasPrefix("Track ") { result.title = String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines) }
                if text.hasPrefix("Артист ") { linkedArtists.append(String(text.dropFirst(7))) }
                if text.hasPrefix("Artist ") { linkedArtists.append(String(text.dropFirst(7))) }
            }
            if let raw = value(e, kAXURLAttribute) {
                let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                if let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    if let id = parts.queryItems?.first(where: { $0.name == "albumId" })?.value { result.albumID = id }
                    if let id = parts.queryItems?.first(where: { $0.name == "trackId" })?.value { result.trackID = id }
                }
                if let url, role == kAXImageRole, url.scheme == "https" { result.artworkURL = url }
            }
            if role == kAXSliderRole && ["Управление таймкодом", "Track progress"].contains(text) {
                result.elapsed = (value(e, kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0
                result.duration = (value(e, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 0
            }
        }
        if linkedArtists.isEmpty, let rawParent = value(player, kAXParentAttribute), CFGetTypeID(rawParent) == AXUIElementGetTypeID() {
            // On My Wave, artists sit immediately beside the player instead of inside it.
            let parent = rawParent as! AXUIElement
            for sibling in children(parent) where !CFEqual(sibling, player) {
                for node in descendants(sibling, limit: 80) {
                    let text = label(node)
                    if value(node, kAXRoleAttribute) as? String == "AXLink", text.hasPrefix("Артист ") {
                        linkedArtists.append(String(text.dropFirst(7)))
                    }
                    if text == "Контекстное меню с артистами" {
                        linkedArtists.append(contentsOf: descendants(node, limit: 30).compactMap {
                            let text = label($0).trimmingCharacters(in: .whitespacesAndNewlines)
                            return value($0, kAXRoleAttribute) as? String == kAXStaticTextRole && !text.isEmpty && text != "," ? text : nil
                        })
                    }
                }
            }
        }
        if !result.title.isEmpty { result.artist = linkedArtists.joined(separator: ", "); return result }
        texts.removeAll { $0 == "Плеер" || $0 == "Player" || $0 == ", " || $0 == "," || $0 == "18+" || $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if texts.count == 1, texts[0].contains(" — ") {
            var text = texts[0]
            let half = text.count / 2
            if text.count > 4 {
                let prefix = String(text.prefix(half)).trimmingCharacters(in: .whitespaces)
                if text == prefix + " " + prefix { text = prefix }
            }
            let split = text.components(separatedBy: " — ")
            result.artist = split.first ?? ""; result.title = split.dropFirst().joined(separator: " — ")
        } else { result.title = texts.last ?? ""; result.artist = texts.dropLast().joined(separator: ", ") }
        if !linkedArtists.isEmpty { result.artist = linkedArtists.joined(separator: ", ") }
        return result.title.isEmpty ? nil : result
    }
    static func press(pid: pid_t, command: String) -> Bool {
        guard let player = player(pid: pid) else { return false }
        let labels: [String]
        switch command {
        case "next": labels = ["Следующая песня", "Next track"]
        case "previous": labels = ["Предыдущая песня", "Previous track"]
        case "like": labels = ["Нравится", "Like"]
        case "toggle": labels = ["Пауза", "Воспроизведение", "Pause", "Play"]
        default: return false
        }
        guard let button = descendants(player, limit: 220).first(where: {
            let role = value($0, kAXRoleAttribute) as? String
            return (role == kAXButtonRole || (command == "like" && role == kAXCheckBoxRole)) && labels.contains(label($0))
        }) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
    static func liked(pid: pid_t) -> Bool? {
        guard let player = player(pid: pid),
              let button = descendants(player, limit: 220).first(where: {
                  value($0, kAXRoleAttribute) as? String == kAXCheckBoxRole && ["Нравится", "Like"].contains(label($0))
              }), let value = value(button, kAXValueAttribute) as? NSNumber else { return nil }
        return value.boolValue
    }
    static func prepareRecentSearch(pid: pid_t, track: RecentMusicTrack) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? children(app)
        let nodes = windows.flatMap { descendants($0, limit: 5000) }
        if let input = nodes.first(where: {
            let role = value($0, kAXRoleAttribute) as? String ?? ""
            let placeholder = value($0, kAXPlaceholderValueAttribute) as? String ?? ""
            return [kAXTextFieldRole, "AXSearchField"].contains(role) &&
                ["Трек, альбом, исполнитель", "Track, album, artist"].contains(placeholder)
        }) {
            let query = track.artist + " " + track.title
            if value(input, kAXValueAttribute) as? String == query { return true }
            return AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, query as CFString) == .success
        }
        if let search = nodes.first(where: {
            value($0, kAXRoleAttribute) as? String == "AXLink" && ["Поиск", "Search"].contains(label($0))
        }) {
            _ = AXUIElementPerformAction(search, kAXPressAction as CFString)
            cachedPlayer = nil
        }
        return false
    }
    static func playRecent(pid: pid_t, track: RecentMusicTrack) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? children(app)
        for window in windows {
            for link in descendants(window, limit: 5000) {
                guard value(link, kAXRoleAttribute) as? String == "AXLink" else { continue }
                let title = label(link).trimmingCharacters(in: .whitespacesAndNewlines)
                guard title == "Трек " + track.title || title == "Track " + track.title else { continue }
                var candidate = MusicSnapshot(title: track.title)
                if let raw = value(link, kAXURLAttribute),
                   let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)),
                   let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    candidate.albumID = parts.queryItems?.first(where: { $0.name == "albumId" })?.value
                    candidate.trackID = parts.queryItems?.first(where: { $0.name == "trackId" })?.value
                }
                // The link can have an extra wrapper. Stop at its own track row;
                // a larger result group must never supply another song's Play button.
                var ancestor = link
                for _ in 0..<4 {
                    guard let rawParent = value(ancestor, kAXParentAttribute), CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { break }
                    ancestor = rawParent as! AXUIElement
                    if ["Плеер", "Player"].contains(label(ancestor)) { break }
                    let nodes = descendants(ancestor, limit: 80)
                    let trackLinks = nodes.filter {
                        value($0, kAXRoleAttribute) as? String == "AXLink" &&
                            (label($0).hasPrefix("Трек ") || label($0).hasPrefix("Track "))
                    }
                    if trackLinks.count > 1 { break }
                    guard trackLinks.count == 1 else { continue }
                    var artists: [String] = []
                    for node in nodes where value(node, kAXRoleAttribute) as? String == "AXLink" {
                        let text = label(node)
                        let artist = text.hasPrefix("Артист ") ? String(text.dropFirst(7)) : text.hasPrefix("Artist ") ? String(text.dropFirst(7)) : ""
                        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !artists.contains(trimmed) { artists.append(trimmed) }
                    }
                    candidate.artist = artists.joined(separator: ", ")
                    candidate.duration = nodes.compactMap { RecentMusicTrack.accessibilityDuration(label($0)) }.first ?? 0
                    guard track.matchesSearchResult(candidate) else { continue }
                    if let play = nodes.first(where: { value($0, kAXRoleAttribute) as? String == kAXButtonRole && ["Воспроизведение", "Play"].contains(label($0)) }) {
                        return AXUIElementPerformAction(play, kAXPressAction as CFString) == .success
                    }
                    if nodes.contains(where: { value($0, kAXRoleAttribute) as? String == kAXButtonRole && ["Пауза", "Pause"].contains(label($0)) }) { return true }
                }
            }
        }
        return false
    }
    static func seek(pid: pid_t, seconds: Double) -> Bool {
        guard let player = player(pid: pid),
              let slider = descendants(player, limit: 220).first(where: {
                  value($0, kAXRoleAttribute) as? String == kAXSliderRole &&
                  ["Управление таймкодом", "Track progress"].contains(label($0))
              }) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(slider, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: seconds)) == .success
    }
}
