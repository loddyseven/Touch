import AppKit
import Darwin

private final class ScreenshotTestLocation: @unchecked Sendable {
    private let lock = NSLock()
    private var folder: URL
    init(_ folder: URL) { self.folder = folder }
    func read() -> [URL] { lock.lock(); defer { lock.unlock() }; return [folder] }
    func change(to folder: URL) { lock.lock(); defer { lock.unlock() }; self.folder = folder }
}

@main
@MainActor
enum Checks {
    private static var count = 0
    @MainActor static func main() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("existing", forType: .string)
        let store = ClipboardStore(board: board, itemLimit: 2)
        store.poll()
        check(store.items.isEmpty, "No clipboard snapshot at launch")
        for value in ["first", "second", "third", "second"] {
            board.clearContents()
            board.setString(value, forType: .string)
            store.poll()
        }
        check(store.items.compactMap(\.text) == ["second", "third"], "Deduplication and item limit")
        for marker in ClipboardStore.privateTypes {
            board.clearContents()
            board.setString("private fixture", forType: .string)
            board.setData(Data(), forType: .init(marker))
            store.poll()
            check(!store.items.contains { $0.text == "private fixture" }, "Ignore private marker: \(marker)")
        }
        store.isPaused = true
        board.clearContents()
        board.setString("paused fixture", forType: .string)
        store.isPaused = false
        store.poll()
        check(store.items.compactMap(\.text) == ["second", "third"], "Pause excludes intervening copies")
        check(store.copy(store.items[1]), "Copy a history entry")
        check(board.string(forType: .string) == "third", "Copied text matches")
        store.clear()
        check(store.items.isEmpty && board.string(forType: .string) == "third", "Clear preserves current clipboard")

        let bounded = ClipboardStore(board: board, memoryLimit: 12)
        for value in ["12345678", "abcdefg"] {
            board.clearContents()
            board.setString(value, forType: .string)
            bounded.poll()
        }
        check(bounded.items.compactMap(\.text) == ["abcdefg"], "Total byte limit")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        board.clearContents()
        board.setData(data, forType: .png)
        store.poll()
        check(store.items.count == 1 && store.items.first?.image != nil, "Image history")
        check(store.copy(store.items[0]) && board.data(forType: .png) == data, "Lossless image copy")

        let screen = NSRect(x: -1512, y: 120, width: 1512, height: 982)
        let geometry = NotchGeometry(screen: screen, topInset: 32,
            left: NSRect(x: -1512, y: 1070, width: 656, height: 32),
            right: NSRect(x: -656, y: 1070, width: 656, height: 32))
        check(geometry.notchWidth == 200 && geometry.frame(expanded: false).midX == -756, "Notch on an offset display")
        check(geometry.frame(expanded: true).maxY == 1102, "Expanded panel anchored to top")
        check(geometry.hoverZone.contains(NSPoint(x: -756, y: 1068)), "Pointer entry below notch")
        check(geometry.recordingFrame.midX == geometry.centerX && geometry.recordingFrame.maxY == screen.maxY, "Compact recording stays aligned with the hardware notch on offset displays")
        check(geometry.recordingFrame.height == geometry.notchHeight + 1 && !geometry.recordingFrame.contains(NSPoint(x: geometry.centerX, y: screen.maxY - 80)), "Clickable recording window does not cover the desktop below the notch")
        check(geometry.recordingFrame.contains(geometry.recordingStopFrame) && geometry.recordingStopFrame.minX > geometry.centerX + geometry.notchWidth / 2, "Compact stop target stays entirely outside the camera cutout")
        check(!geometry.recordingStopFrame.contains(NSPoint(x: geometry.centerX - geometry.closedSize.width / 2 - 20, y: screen.maxY - 16)), "Timer side remains available for hover expansion")

        let fallback = NotchGeometry(screen: screen, topInset: 0, left: nil, right: nil)
        check(fallback.frame(expanded: true).midX == screen.midX, "Display without notch")
        setupChecks()
        spectrumChecks()
        marqueeChecks(check: { check($0, $1) })
        check(PlaybackPosition.clamped(-20, duration: 142) == 0, "Seeking before the track clamps to its start")
        check(PlaybackPosition.clamped(200, duration: 142) == 142, "Seeking after the track clamps to its end")
        check(PlaybackPosition.clamped(.nan, duration: 142) == nil && PlaybackPosition.clamped(20, duration: 0) == nil, "Unknown duration and invalid seek values do not reach the player")
        check(PlaybackPosition.microseconds(13.125) == 13_125_000, "Bridge seeks use microseconds, including subsecond positions")
        check(PlaybackPosition.microseconds(.infinity) == nil && PlaybackPosition.microseconds(Double.greatestFiniteMagnitude) == nil, "Bridge rejects nonfinite and overflowing positions")
        let music = MusicController()
        music.isFixture = true; music.connected = true; music.title = "Seek fixture"; music.duration = 142
        music.seek(to: 36)
        check(music.elapsed == 36 && !music.playing, "Seeking a paused track preserves its paused state")
        music.playing = true; music.seek(to: 84)
        check(music.elapsed == 84 && music.playing, "Seeking a playing track preserves playback")
        music.connected = false; music.seek(to: 12)
        check(music.elapsed == 84, "Disconnected tracks cannot be scrubbed")
        let seekStart = Date(timeIntervalSince1970: 1000)
        let pendingSeek = PendingPlaybackSeek(target: 80, track: "song", started: seekStart)
        check(pendingSeek.shouldHold(actual: 20, track: "song", at: seekStart.addingTimeInterval(0.4), playing: true), "Late player updates cannot snap a seek back to the old position")
        check(!pendingSeek.shouldHold(actual: 80.4, track: "song", at: seekStart.addingTimeInterval(0.4), playing: true), "A matching player acknowledgement releases the seek preview")
        check(pendingSeek.position(at: seekStart.addingTimeInterval(1), playing: false) == 80, "Paused seek previews never drift")
        check(!pendingSeek.shouldHold(actual: 0, track: "new song", at: seekStart.addingTimeInterval(0.2), playing: true), "Changing tracks discards the old seek preview")
        check(!pendingSeek.shouldHold(actual: 20, track: "song", at: seekStart.addingTimeInterval(5), playing: true), "An unacknowledged seek cannot pin the timeline forever")
        var recentMusic = RecentMusic()
        check(!recentMusic.record(title: " \n ", artist: "", duration: 0, artwork: nil), "Empty metadata does not create a recent track")
        let recentCover = NSImage(size: NSSize(width: 4, height: 4))
        recentMusic.record(title: "One", artist: "Artist", duration: 90, artwork: recentCover)
        check(!recentMusic.record(title: "One", artist: "Artist", duration: 90, artwork: recentCover), "Progress-only updates do not rebuild recent tracks")
        recentMusic.record(title: "Two", artist: "Artist", duration: 80, artwork: nil)
        recentMusic.record(title: "Three", artist: "Artist", duration: 70, artwork: nil)
        recentMusic.record(title: "One", artist: "Artist", duration: 90, artwork: nil)
        check(recentMusic.tracks.map(\.title) == ["One", "Three", "Two"] && recentMusic.tracks.first?.artwork === recentCover, "Replaying a recent track moves it first and preserves its cover")
        recentMusic.record(title: "Four", artist: "Artist", duration: .nan, artwork: nil)
        check(recentMusic.tracks.count == 3 && recentMusic.tracks.first?.duration == 0, "Recent history stays bounded and rejects invalid duration")
        recentMusic.record(title: "Four", artist: "Another artist", duration: 50, artwork: nil)
        check(recentMusic.tracks[0].id != recentMusic.tracks[1].id, "Identical titles by different artists stay distinct")
        var partialMusic = RecentMusic()
        partialMusic.record(title: "Ближе", artist: "", duration: 0, artwork: nil)
        partialMusic.record(title: "Ближе", artist: "Полка", duration: 111, artwork: recentCover, albumID: "39677315", trackID: "145371648")
        check(partialMusic.tracks.count == 1 && partialMusic.tracks[0].artist == "Полка", "Artist and artwork enrichment replaces partial metadata without duplicates")
        partialMusic.record(title: "Ближе", artist: "", duration: 0, artwork: nil)
        check(partialMusic.tracks.count == 1 && partialMusic.tracks[0].artwork === recentCover && partialMusic.tracks[0].duration == 111, "Incomplete refresh preserves known artist cover and duration")
        check(partialMusic.tracks[0].albumURL?.absoluteString == "yandexmusic://album/39677315" && partialMusic.tracks[0].trackID == "145371648", "Recent playback retains the exact catalog destination")
        partialMusic.record(title: "Ближе", artist: "Other", duration: 92, artwork: nil)
        check(!partialMusic.record(title: "Ближе", artist: "", duration: 0, artwork: nil) && partialMusic.tracks.count == 2, "Ambiguous incomplete metadata cannot merge two artists")
        partialMusic.record(title: "Invalid destination", artist: "Artist", duration: 90, artwork: nil, albumID: "12/../../bad")
        check(partialMusic.tracks[0].albumURL == nil, "Invalid album identifiers cannot create a playback URL")
        let confirmedSong = RecentMusicTrack(id: "COW", title: "COW", artist: "FRIENDLY THUG 52 NGG", duration: 130, artwork: nil)
        check(confirmedSong.agrees(with: MusicSnapshot(title: "COW", artist: "FRIENDLY THUG 52 NGG", duration: 130)), "A complete player snapshot confirms recent metadata")
        check(!confirmedSong.agrees(with: MusicSnapshot(title: "COW", artist: "OG Buda, 163ONMYNECK", duration: 126)), "New title with previous artists cannot enter history")
        check(!confirmedSong.agrees(with: MusicSnapshot(title: "SST", artist: "FRIENDLY THUG 52 NGG", duration: 130)), "Artist and cover updates cannot rename the previous song")
        check(!confirmedSong.agrees(with: MusicSnapshot(title: "COW", artist: "", duration: 130)), "Artist-less snapshots do not confirm history")
        check(!confirmedSong.agrees(with: MusicSnapshot(title: "COW", artist: "FRIENDLY THUG 52 NGG", duration: 186)), "A different track version cannot confirm recent playback")
        let recentWithID = RecentMusicTrack(id: "Сутки", title: "Сутки", artist: "FLOCKAA", duration: 116, artwork: nil, albumID: "12", trackID: "34")
        check(recentWithID.matchesSearchResult(MusicSnapshot(title: "Сутки", artist: "FLOCKAA", duration: 116)), "A complete search result remains playable when Electron omits AXURL query IDs")
        check(!recentWithID.matchesSearchResult(MusicSnapshot(title: "Сутки", artist: "Someone else", duration: 116)), "Missing IDs cannot select the same title from another artist")
        check(!recentWithID.matchesSearchResult(MusicSnapshot(title: "Сутки", artist: "FLOCKAA", duration: 160)), "Missing IDs cannot select a different version with another duration")
        check(!recentWithID.matchesSearchResult(MusicSnapshot(title: "Сутки", artist: "FLOCKAA")), "A result without IDs or duration is not enough to select a known recording")
        check(!recentWithID.matchesSearchResult(MusicSnapshot(title: "Сутки", artist: "FLOCKAA", duration: 116, trackID: "999")), "An explicit conflicting track ID is rejected")
        check(recentWithID.matchesSearchResult(MusicSnapshot(title: "Сутки", artist: "FLOCKAA", trackID: "34")), "A matching track ID works before its duration is exposed")
        check(RecentMusicTrack.accessibilityDuration(" 1 минута, 56 секунд.") == 116, "Russian Yandex result duration")
        check(RecentMusicTrack.accessibilityDuration(" 2 минуты, ") == 120, "Exact-minute duration without seconds")
        check(RecentMusicTrack.accessibilityDuration("1 hour, 2 minutes, 3 seconds") == 3723, "English result duration")
        check(RecentMusicTrack.accessibilityDuration("2:03") == 123 && RecentMusicTrack.accessibilityDuration("1:02:03") == 3723, "Clock-shaped durations")
        check(RecentMusicTrack.accessibilityDuration("FLOCKAA Сутки") == nil, "A track name is not mistaken for duration")

        check(recentWithID.confirmsPlayback(MusicSnapshot(playing: true, trackID: "34")), "A playing track ID confirms startup while artist and duration are still loading")
        check(!recentWithID.confirmsPlayback(MusicSnapshot(title: "Сутки", artist: "FLOCKAA", playing: true, duration: 116, trackID: "999")), "Stale same-title metadata cannot confirm a different playing ID")
        check(!recentWithID.confirmsPlayback(MusicSnapshot(title: "Сутки", artist: "FLOCKAA", duration: 116, trackID: "34")), "A paused target is not reported as playing")
        check(!recentWithID.confirmsPlayback(MusicSnapshot(title: "Сутки", playing: true)), "Incomplete metadata without an ID cannot confirm playback")
        let playbackStart = Date(timeIntervalSince1970: 1000)
        var attempt = RecentPlaybackAttempt(track: recentWithID, started: playbackStart)
        check(!attempt.timedOut(at: playbackStart.addingTimeInterval(10)), "Search gets a bounded loading interval")
        attempt.didPress(at: playbackStart.addingTimeInterval(11))
        attempt.didPress(at: playbackStart.addingTimeInterval(20))
        check(attempt.pressedAt == playbackStart.addingTimeInterval(11), "Duplicate action completion cannot extend the playback deadline")
        check(!attempt.timedOut(at: playbackStart.addingTimeInterval(19)) && attempt.confirmed(by: MusicSnapshot(playing: true, trackID: "34")), "A delayed eight-second load confirms playback instead of timing out after 2.5 seconds")
        check(attempt.timedOut(at: playbackStart.addingTimeInterval(23)), "A player that never starts still times out")

        music.artist = "Fixture artist"
        music.connected = true; music.recordCurrentTrack()
        check(music.recentTracks.first?.title == "Seek fixture", "The collection shows observed track metadata")
        music.connected = false; music.title = "Disconnected fixture"; music.recordCurrentTrack()
        check(music.recentTracks.count == 1, "Disconnected metadata does not enter listening history")
        do { try captureChecks(png: data, board: board); try systemCaptureChecks(png: data); try converterSourceChecks(); try shelfChecks(board: board); try clearChecks(png: data); try recordingChecks(check: { check($0, $1) }) }
        catch { fputs("FAIL: temporary fixtures: \(error)\n", stderr); exit(1) }
        print("All \(count) checks passed.")
    }

    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
        print("PASS: \(name)")
    }

    private static func spectrumChecks() {
        func analyze(rate: Double = 48000, signal: (Double) -> Double) -> (peak: Double, hits: [Double], last: Double) {
            let analyzer = SpectrumAnalyzer(); var peak = 0.0, last = 0.0, hits: [Double] = []
            for sample in 0..<Int(rate * 3) {
                let time = Double(sample) / rate
                if let values = analyzer.feed(Float(signal(time)), sampleRate: rate) {
                    let level = values.max() ?? 0
                    peak = max(peak, level)
                    if level > last + 0.12 { hits.append(time) }
                    last = level
                }
            }
            return (peak, hits, last)
        }
        func kick(_ time: Double, amplitude: Double = 0.4) -> Double {
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            guard phase < 0.3 else { return 0 }
            let angle = 2 * Double.pi * (52 * phase + 80 * 0.016 * (1 - exp(-phase / 0.016)))
            return amplitude * sin(angle) * exp(-phase / 0.075) * (1 - exp(-phase / 0.001))
        }
        for rate in [44100.0, 48000, 96000] {
            let result = analyze(rate: rate, signal: { kick($0) })
            check(result.hits.count == 6, "Six kick attacks produce six pulses at \(Int(rate)) Hz")
            check(result.hits.enumerated().allSatisfy { $0.element - Double($0.offset) * 0.5 < 0.15 }, "Beat detection stays within 150ms at \(Int(rate)) Hz")
            check(result.last < 0.13, "Beat envelope settles between drum hits at \(Int(rate)) Hz")
        }
        let quiet = analyze(signal: { kick($0, amplitude: 0.06) })
        check(quiet.hits.count == 6 && quiet.peak < analyze(signal: { kick($0) }).peak, "Quiet kicks remain visible without reaching the loud-hit peak")
        let voice = analyze(signal: { time in
            let amplitude = 0.45 + 0.25 * sin(2 * Double.pi * 4 * time)
            return amplitude * (0.5 * sin(2 * .pi * 175 * time) + 0.3 * sin(2 * .pi * 350 * time) + 0.2 * sin(2 * .pi * 700 * time))
        })
        check(voice.peak < 0.01, "Modulated vocal-range harmonics do not drive the beat bars")
        let lowVoice = analyze(signal: { time in
            let amplitude = 0.45 + 0.25 * sin(2 * Double.pi * 4 * time)
            return amplitude * (0.35 * sin(2 * .pi * 90 * time) + 0.4 * sin(2 * .pi * 180 * time) + 0.25 * sin(2 * .pi * 360 * time))
        })
        check(lowVoice.peak < 0.01, "A low vocal fundamental with speech harmonics is rejected")
        check(analyze(signal: { 0.4 * sin(2 * .pi * 65 * $0) }).peak < 0.01, "Sustained bass does not create artificial beats")
        check(analyze(signal: { kick($0) + 0.18 * sin(2 * .pi * 175 * $0) + 0.14 * sin(2 * .pi * 350 * $0) }).hits.count == 6, "Kick attacks remain detectable under vocal-range harmonics")
        check(analyze(signal: { _ in 0 }).peak == 0, "Silence produces no artificial movement")
        let invalid = SpectrumAnalyzer()
        check(invalid.feed(1, sampleRate: .nan) == nil && invalid.feed(1, sampleRate: 0) == nil, "Invalid sample rates never reach FFT bin conversion")
        var finite = true
        for _ in 0..<(SpectrumAnalyzer.size * 3) {
            if let levels = invalid.feed(.infinity, sampleRate: 48000) { finite = finite && levels.allSatisfy { $0.isFinite && $0 == 0 } }
        }
        check(finite, "Nonfinite input samples cannot animate or poison the analyzer")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        for offset in stride(from: 0, to: 8 * 8 * 4, by: 4) {
            bitmap.bitmapData![offset] = 204
            bitmap.bitmapData![offset + 1] = 20
            bitmap.bitmapData![offset + 2] = 38
            bitmap.bitmapData![offset + 3] = 255
        }
        let cover = NSImage(size: NSSize(width: 8, height: 8)); cover.addRepresentation(bitmap)
        let accent = ArtworkPalette.accent(cover).usingColorSpace(.deviceRGB)!
        check(accent.redComponent > accent.greenComponent + 0.2 && accent.redComponent > accent.blueComponent + 0.2, "Visualizer accent follows the cover hue")
    }

    private static func shelfChecks(board: NSPasteboard) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Touch-shelf-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Report.pdf")
        try Data("fixture".utf8).write(to: file)
        let shelf = FileShelfStore(defaults: nil)
        shelf.add([file, file, folder, URL(string: "https://example.com/file")!])
        check(shelf.files.count == 2, "Shelf deduplicates local files and folders, rejects remote URLs")
        check(shelf.selectedURLs.count == 2, "Added files selected together")
        check(shelf.copySelected(to: board), "Shelf copies file URLs for Finder paste")
        check((board.readObjects(forClasses: [NSURL.self]) ?? []).count == 2, "All selected files copied")
        shelf.select(file.standardizedFileURL.resolvingSymlinksInPath(), extending: false)
        shelf.removeSelected()
        check(FileManager.default.fileExists(atPath: file.path), "Removing from shelf preserves original file")
        check(shelf.files.count == 1 && shelf.selected.isEmpty, "Remove clears only chosen shelf entries")
        let missing = folder.appendingPathComponent("missing.mov")
        shelf.add([missing]); check(shelf.files.count == 1, "Missing file cannot be added")
        let narrow = NotchGeometry(screen: NSRect(x: 0, y: 0, width: 1024, height: 768), topInset: 0, left: nil, right: nil)
        check(narrow.openSize.width < narrow.screen.width, "Wide panel stays inside display")
    }

    private static func clearChecks(png: Data) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Touch-clear-checks-\(UUID())")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "Touch-clear-checks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: folder); preferences.removePersistentDomain(forName: suite) }
        let photo = folder.appendingPathComponent("Capture.png"), video = folder.appendingPathComponent("Video.mp4")
        try png.write(to: photo); try Data("video fixture".utf8).write(to: video)
        let captures = CaptureStore(folder: folder, defaults: preferences)
        captures.selectAll(); captures.clear()
        check(captures.items.isEmpty && captures.selectedIDs.isEmpty && captures.canUndoClear, "Clearing captures resets selection and offers undo")
        let savedPhoto = try Data(contentsOf: photo)
        check(savedPhoto == png && fm.fileExists(atPath: video.path), "Gallery clear preserves original screenshots and videos")
        captures.refresh()
        check(captures.items.isEmpty, "Rescanning cannot restore cleared captures")
        check(CaptureStore(folder: folder, defaults: preferences).items.isEmpty, "Cleared captures stay hidden after restarting Touch")
        let fresh = folder.appendingPathComponent("New.png")
        try png.write(to: fresh); captures.refresh()
        check(captures.items.map(\.url) == [fresh.standardizedFileURL], "New screenshots still appear after clearing the gallery")
        captures.undoClear()
        check(captures.items.count == 3 && !captures.canUndoClear, "Undo restores old captures alongside new captures")
        captures.select(photo.standardizedFileURL); captures.removeSelected(); captures.refresh()
        check(captures.items.count == 2 && !captures.items.contains { $0.url == photo.standardizedFileURL }, "Remove selection hides only chosen captures")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: photo.path)
        captures.refresh()
        check(captures.items.count == 3, "A new file revision at a cleared path is not suppressed")
        let shelf = FileShelfStore(defaults: preferences)
        shelf.add([photo, video]); shelf.clear()
        check(shelf.files.isEmpty && shelf.selected.isEmpty && shelf.canUndoClear, "Clearing files removes all shelf entries and selection")
        check(FileShelfStore(defaults: preferences).files.isEmpty, "File shelf remains empty after relaunch")
        check(fm.fileExists(atPath: photo.path) && fm.fileExists(atPath: video.path), "Clearing files does not delete originals")
        shelf.add([photo]); shelf.undoClear()
        check(shelf.files.count == 2 && Set(shelf.files.map(\.url)).count == 2, "Undo file clear merges newly added entries without duplicates")
        check(FileShelfStore(defaults: preferences).files.count == 2, "Undo file clear persists restored entries")
    }

    private static func converterSourceChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Touch-source-checks-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.MOV")
        let second = root.appendingPathComponent("Second.mp4")
        let text = root.appendingPathComponent("Notes.txt")
        for url in [first, second, text] { try Data("fixture".utf8).write(to: url) }
        let converter = VideoConverter()
        converter.setSources([first])
        check(converter.inputs == [first], "Individual video chosen directly from the system picker")
        check(converter.destinationFolder == root.appendingPathComponent("Converted", isDirectory: true), "Single-video output sits beside its source")
        converter.setSources([root])
        check(Set(converter.inputs.map(\.standardizedFileURL.path)) == Set([first, second].map(\.standardizedFileURL.path)), "Folder expands into supported videos")
        converter.setSources([first, root, second])
        check(converter.inputs.count == 2, "Mixed file and folder selection deduplicates videos")
        converter.setSources([text])
        check(converter.inputs.isEmpty && converter.message != nil, "Unsupported selection has an actionable empty state")
        let output = root.appendingPathComponent("Selected output", isDirectory: true)
        converter.destination = output
        converter.setSources([first])
        check(converter.destinationFolder == output, "Explicit output folder is preserved")
    }

    private static func setupChecks() {
        let screen = NSRect(x: -1512, y: 120, width: 1512, height: 982)
        let notched = MacDisplay(name: "Fixture", frame: screen, topInset: 32,
            left: NSRect(x: -1512, y: 1070, width: 656, height: 32),
            right: NSRect(x: -656, y: 1070, width: 656, height: 32))
        let plain = MacDisplay(name: "External", frame: screen, topInset: 0, left: nil, right: nil)
        let mac = MacSnapshot(identifier: "Mac16,6", display: notched)
        check(MacFamily.identify("Mac16,6") == .pro14 && MacFamily.identify("Mac17,4") == .air15, "Known Mac model families")
        check(MacFamily.identify("Mac99,999") == nil, "Future model is explicitly unrecognized")
        check(MacVerification.evaluate(selected: .pro14, snapshot: mac) == .confirmed, "Matching model verifies")
        check(!MacVerification.evaluate(selected: .pro16, snapshot: mac).canContinue, "Mismatched model cannot confirm setup")
        check(MacVerification.evaluate(selected: .other, snapshot: MacSnapshot(identifier: "", display: plain)) == .unrecognized, "Failed model read does not pretend to verify")
        check(!MacVerification.evaluate(selected: .pro14, snapshot: MacSnapshot(identifier: "Mac16,6", display: nil)).canContinue, "Missing screen blocks completion")
        check(notched.hasNotch && notched.geometry.notchWidth == 200, "Display supplies measured notch width")
        check(!plain.hasNotch && plain.geometry.notchHeight == 24, "Unnotched display uses compact geometry")
        let malformed = MacDisplay(name: "Malformed", frame: screen, topInset: 0, left: notched.left, right: notched.right)
        check(!malformed.hasNotch, "Top rectangles alone cannot fabricate a notch")
        let reversed = MacDisplay(name: "Reversed", frame: screen, topInset: 32, left: notched.right, right: notched.left)
        check(!reversed.hasNotch, "Invalid notch measurements fall back safely")
        let wide = NotchGeometry(screen: screen, topInset: 40,
            left: NSRect(x: -1512, y: 1062, width: 556, height: 40),
            right: NSRect(x: -556, y: 1062, width: 556, height: 40))
        check(wide.expandedWidth >= wide.closedSize.width && wide.openSize.width > wide.expandedWidth, "Wide notch remains inside the expanded surface")
        let suite = "Touch-setup-checks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var hardware = mac
        let setup = MacSetup(defaults: preferences, readHardware: { hardware })
        check(MacSetup.needsSetup(preferences), "First run requires setup")
        check(!setup.complete(), "Unverified setup is not persisted")
        setup.selected = .pro16; setup.verify(animated: false)
        check(!setup.complete() && MacSetup.needsSetup(preferences), "Mismatch cannot mark setup complete")
        setup.selected = .pro14; setup.verify(animated: false)
        hardware = MacSnapshot(identifier: "Mac16,6", display: nil)
        check(!setup.complete(), "Screen removed before confirmation is rechecked")
        hardware = MacSnapshot(identifier: "Mac16,6", display: plain)
        setup.verify(animated: false)
        check(setup.complete() && !MacSetup.needsSetup(preferences), "Confirmed model can use an unnotched external display")
        check(setup.snapshot.display?.hasNotch == false, "Final geometry comes from the current display")
        let unknown = MacSetup(defaults: preferences, readHardware: { MacSnapshot(identifier: "Mac99,999", display: notched) })
        unknown.verify(animated: false)
        check(unknown.verification == .unrecognized && unknown.complete(), "Unknown model can proceed using measured screen geometry")
    }

    private static func captureChecks(png: Data, board: NSPasteboard) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHub-checks-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<26 { try png.write(to: folder.appendingPathComponent("Снимок \(index).png")) }
        try Data("unrelated".utf8).write(to: folder.appendingPathComponent("note.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory.png"), withIntermediateDirectories: false)
        let store = CaptureStore(folder: folder)
        check(store.items.count == 26, "Gallery indexes all PNG files, excludes directories and other files")
        check(CaptureStore(folder: folder).items.map(\.id) == store.items.map(\.id), "Gallery survives a store restart")
        let first = store.items[0], second = store.items[1], third = store.items[2]
        check(first.thumbnail != nil, "Gallery generates a thumbnail from the saved PNG")
        store.select(first.id)
        store.select(second.id, extending: true)
        check(store.selectedIDs == [first.id, second.id], "Option selection adds a second screenshot")
        store.select(second.id, extending: true)
        check(store.selectedIDs == [first.id], "Option selection toggles a screenshot off")
        store.select(folder.appendingPathComponent("missing.png"), extending: true)
        check(store.selectedIDs == [first.id], "Unknown screenshots cannot enter selection")
        store.select(second.id, extending: true)
        check(Set(store.dragCaptures(startingAt: first.id).map(\.id)) == [first.id, second.id], "Dragging a selected member preserves the group")
        let dragItems = CaptureTileView.draggingItems(for: store.selectedCaptures, origin: .zero)
        check(dragItems.count == 2 && Set(dragItems.compactMap { ($0.item as? NSURL).map { $0 as URL } }) == [first.id, second.id],
            "Native drag contains one original file URL per screenshot")
        check(store.copySelected(to: board), "Copy a selection of screenshots")
        let copied = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        check(Set(copied ?? []) == [first.id, second.id], "Pasteboard round-trip preserves both file URLs")
        let original = try Data(contentsOf: first.url)
        check(original == png, "Copy leaves the original PNG unchanged")

        let tile = CaptureTileView(capture: first, store: store)
        func mouse(_ type: NSEvent.EventType, option: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: option ? [.option] : [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        tile.mouseDown(with: mouse(.leftMouseDown))
        check(store.selectedIDs.count == 2, "Mouse-down on a selected tile retains the group for dragging")
        tile.mouseUp(with: mouse(.leftMouseUp))
        check(store.selectedIDs == [first.id], "Ordinary click selects only one tile on mouse-up")
        let secondTile = CaptureTileView(capture: second, store: store)
        secondTile.mouseDown(with: mouse(.leftMouseDown, option: true))
        secondTile.mouseUp(with: mouse(.leftMouseUp, option: true))
        check(store.selectedIDs == [first.id, second.id], "Native Option-click adds without toggling twice")
        secondTile.mouseDown(with: mouse(.leftMouseDown, option: true))
        secondTile.mouseUp(with: mouse(.leftMouseUp, option: true))
        check(store.selectedIDs == [first.id], "Native Option-click removes an already selected tile")
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "ф", charactersIgnoringModifiers: "ф", isARepeat: false, keyCode: 0)!
        tile.keyDown(with: selectAll)
        check(store.selectedIDs.count == 26, "Command-A works with a Russian keyboard layout")
        store.select(first.id)
        store.select(second.id, extending: true)
        check(store.dragCaptures(startingAt: third.id).map(\.id) == [third.id], "Dragging an unselected screenshot starts a new selection")
        store.beginDrag()
        check(store.isDragging, "Drag keeps the panel open")
        store.finishDrag()
        check(!store.isDragging, "Ending or cancelling a drag releases the panel")

        store.select(first.id)
        store.select(second.id, extending: true)
        try FileManager.default.removeItem(at: second.url)
        let changeCount = board.changeCount
        check(!store.copySelected(to: board) && board.changeCount == changeCount, "Missing file does not clear the clipboard")
        check(store.selectedIDs == [first.id], "Refresh prunes deleted files from the selection")
        store.select(third.id, extending: true)
        try FileManager.default.removeItem(at: third.url)
        check(store.dragCaptures(startingAt: first.id).isEmpty, "Missing member cancels the whole drag instead of silently sending part")
        store.clearSelection()
        check(!store.copySelected(to: board) && board.changeCount == changeCount, "Empty selection preserves the clipboard")
        store.selectAll()
        check(store.selectedIDs.count == 24, "Select all includes the remaining saved screenshots")
    }

    private static func systemCaptureChecks(png: Data) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Touch-system-capture-checks-\(UUID())")
        let own = root.appendingPathComponent("Touch"), desktop = root.appendingPathComponent("Desktop")
        let custom = root.appendingPathComponent("Custom Screenshots")
        for folder in [own, desktop, custom] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        func markScreenshot(_ url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            let result = data.withUnsafeBytes { bytes in
                setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
            }
            guard result == 0 else { throw POSIXError(.EIO) }
        }
        func wait(_ condition: () -> Bool, timeout: TimeInterval = 4) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return condition()
        }
        let existing = desktop.appendingPathComponent("Unusual localized name.png")
        try png.write(to: existing); try markScreenshot(existing)
        let normal = desktop.appendingPathComponent("Screenshot 2026-09-25.png")
        try png.write(to: normal)
        try png.write(to: own.appendingPathComponent("In-app.png"))
        let location = ScreenshotTestLocation(desktop)
        let store = CaptureStore(folder: own, systemCaptureDirectories: { location.read() })
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let shelf = FileShelfStore(defaults: nil)
        let model = AppModel(clipboard: ClipboardStore(board: board), captures: store, shelf: shelf)
        _ = model
        check(wait { store.items.count == 2 }, "System screenshots join the native gallery alongside in-app captures")
        check(!store.items.contains { $0.url == normal }, "Ordinary pictures are excluded even when named Screenshot")
        check(shelf.files.isEmpty, "Existing screenshot history does not flood the Home shelf at startup")

        let fresh = desktop.appendingPathComponent("⌘⇧3.png")
        try png.write(to: fresh); try markScreenshot(fresh)
        check(wait { store.items.contains { $0.url == fresh } }, "Directory event adds a system screenshot without reopening Touch")
        check(wait { shelf.files.contains { $0.url == fresh } }, "System screenshots also appear on the Home shelf")
        let original = try Data(contentsOf: fresh)
        check(original == png, "Monitoring preserves the original screenshot bytes")
        store.refresh(); store.refresh()
        check(wait { store.items.filter { $0.url == fresh }.count == 1 }, "Repeated scans do not duplicate screenshots")

        let late = desktop.appendingPathComponent("⌘⇧4.png")
        try Data(png.prefix(12)).write(to: late); try markScreenshot(late)
        check(Capture.read(late, systemOnly: true) == nil, "A screenshot still being written is not exposed as a broken thumbnail")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try png.write(to: late)
        check(wait { store.items.contains { $0.url == late } }, "Partial screenshot is retried after the system finishes writing it")

        let jpeg = desktop.appendingPathComponent("Capture.jpg")
        let jpegData = NSBitmapImageRep(data: png)!.representation(using: .jpeg, properties: [:])!
        try jpegData.write(to: jpeg); try markScreenshot(jpeg)
        check(wait { store.items.contains { $0.url == jpeg } }, "System JPEG screenshots are supported as well as PNG")
        check(store.items.first(where: { $0.url == jpeg })?.thumbnail != nil, "Imported JPEG has a usable thumbnail")

        let delayedMetadata = desktop.appendingPathComponent("Metadata arrives later.png")
        try png.write(to: delayedMetadata)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try markScreenshot(delayedMetadata)
        check(wait({ store.items.contains { $0.url == delayedMetadata } }, timeout: 7), "Late screenshot metadata is picked up without another folder write")

        store.select(fresh)
        try fm.removeItem(at: fresh)
        check(wait { !store.items.contains { $0.url == fresh } && store.selectedIDs.isEmpty }, "Deleting an original removes its gallery entry and stale selection")

        location.change(to: custom)
        let redirected = custom.appendingPathComponent("Custom screenshot.png")
        try png.write(to: redirected); try markScreenshot(redirected)
        check(wait({ store.items.contains { $0.url == redirected } }, timeout: 7), "Changing the macOS screenshot destination is followed while Touch runs")
        check(!store.items.contains { $0.url == existing }, "Old destination watcher and results are replaced after changing the destination")
        check(store.items.contains { $0.url.lastPathComponent == "In-app.png" }, "Changing the system destination preserves Touch's own captures")
        try fm.removeItem(at: own)
        store.refresh()
        check(store.items.contains { $0.url == redirected }, "System screenshots work even before Touch's own capture folder exists")
        store.clear(); store.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check(store.items.isEmpty && fm.fileExists(atPath: redirected.path), "Clearing imported system screenshots survives a monitor rescan and preserves originals")
        let afterClear = custom.appendingPathComponent("After clear.png")
        try png.write(to: afterClear); try markScreenshot(afterClear)
        check(wait { store.items.map(\.url) == [afterClear] }, "System screenshot monitoring continues after clearing")
    }
}
