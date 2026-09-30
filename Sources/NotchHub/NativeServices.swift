import AppKit
import AVFoundation
import Combine
import Vision
import UniformTypeIdentifiers

@MainActor
final class TextScanner: ObservableObject {
    @Published var text = ""
    @Published var image: NSImage?
    @Published private(set) var busy = false
    @Published var message: String?

    func recognize(_ url: URL) {
        guard !busy else { return }
        busy = true
        message = nil
        image = NSImage(contentsOf: url)
        text = ""
        Task {
            do {
                text = try await Task.detached(priority: .userInitiated) { try Self.readText(url) }.value
                if text.isEmpty { message = "Текст не найден. Попробуй выбрать область крупнее." }
            } catch { message = "Не удалось прочитать текст: \(error.localizedDescription)" }
            busy = false
        }
    }

    nonisolated static func readText(_ url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url)
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    func copy() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = nil
    }
}

enum VideoQuality: String, CaseIterable {
    case high = "Высокое", balanced = "Баланс", compact = "Компактно"
    var preset: String {
        switch self {
        case .high: return AVAssetExportPresetHighestQuality
        case .balanced: return AVAssetExportPreset1920x1080
        case .compact: return AVAssetExportPreset1280x720
        }
    }
}

private final class FFmpegProgressReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    func read(_ data: Data) -> Double? {
        lock.lock(); defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        let lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
        pending = String(lines.last ?? "")
        return lines.dropLast().reversed().compactMap { line -> Double? in
            guard line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)) else { return nil }
            return value / 1_000_000
        }.first
    }
}

@MainActor
final class VideoConverter: ObservableObject {
    @Published var source: URL?
    @Published var destination: URL?
    @Published var format = "MP4"
    @Published var quality: VideoQuality = .high
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published var message: String?
    @Published private(set) var inputs: [URL] = []
    @Published private(set) var completedCount = 0
    @Published private(set) var failureCount = 0
    private var export: AVAssetExportSession?
    private var process: Process?
    private var cancelled = false
    private var progressTimer: Timer?
    static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
    var formats: [String] { Self.ffmpegURL == nil ? ["MP4", "MOV"] : ["MP4", "MOV", "MKV"] }
    static var supportedExtensions: [String] {
        let native = ["mp4", "mov", "m4v", "avi", "mpeg", "mpg"]
        return ffmpegURL == nil ? native : native + ["mkv", "webm"]
    }
    var destinationFolder: URL? {
        if let destination { return destination }
        guard let source else { return nil }
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let parent = isFolder ? source : source.deletingLastPathComponent()
        return parent.appendingPathComponent("Converted", isDirectory: true)
    }

    func setSource(_ url: URL) { setSources([url]) }

    func setSources(_ urls: [URL]) {
        guard !running else { return }
        source = urls.first
        var candidates: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                candidates += (try? FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            } else { candidates.append(url) }
        }
        var seen = Set<URL>()
        inputs = candidates.filter { url in
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            return seen.insert(url.standardizedFileURL.resolvingSymlinksInPath()).inserted
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        progress = 0; completedCount = 0; failureCount = 0
        message = inputs.isEmpty ? "В выбранных файлах и папках нет поддерживаемых видео" : nil
    }

    func cancel() {
        cancelled = true
        export?.cancelExport()
        if let process, process.isRunning { process.terminate() }
    }

    func convert() {
        guard !running, !inputs.isEmpty, formats.contains(format), let folder = destinationFolder else { return }
        running = true; cancelled = false; progress = 0; completedCount = 0; failureCount = 0
        let sources = inputs, chosenFormat = format, chosenQuality = quality
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, url) in sources.enumerated() {
                    if cancelled { break }
                    message = "\(index + 1) из \(sources.count)"
                    let suffix = chosenFormat.lowercased()
                    let stage = folder.appendingPathComponent(".touch-\(UUID().uuidString).\(suffix)")
                    let ffmpegNeeded = chosenFormat == "MKV" || ["mkv", "webm"].contains(url.pathExtension.lowercased())
                    let success: Bool
                    if ffmpegNeeded {
                        success = await exportFFmpeg(url, to: stage, format: chosenFormat, quality: chosenQuality, index: index, count: sources.count)
                    } else {
                        success = await exportNative(url, to: stage, format: chosenFormat, quality: chosenQuality, index: index, count: sources.count)
                    }
                    if success && !cancelled {
                        do {
                            let output = Self.uniqueOutput(in: folder, stem: url.deletingPathExtension().lastPathComponent, suffix: suffix)
                            try FileManager.default.moveItem(at: stage, to: output)
                            completedCount += 1
                        } catch { failureCount += 1 }
                    } else if !cancelled { failureCount += 1 }
                    try? FileManager.default.removeItem(at: stage)
                    progress = Double(index + 1) / Double(sources.count)
                }
                message = cancelled ? "Остановлено · готово: \(completedCount)" : failureCount > 0 ? "Готово: \(completedCount) · не удалось: \(failureCount)" : nil
            } catch { message = "Не удалось сохранить видео: \(error.localizedDescription)" }
            progressTimer?.invalidate(); progressTimer = nil; export = nil; process = nil; running = false
        }
    }

    private func exportNative(_ url: URL, to output: URL, format: String, quality: VideoQuality, index: Int, count: Int) async -> Bool {
        let asset = AVURLAsset(url: url), type: AVFileType = format == "MOV" ? .mov : .mp4
        guard let session = AVAssetExportSession(asset: asset, presetName: quality.preset), session.supportedFileTypes.contains(type) else { return false }
        session.outputURL = output; session.outputFileType = type; session.shouldOptimizeForNetworkUse = true
        export = session
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.progress = (Double(index) + Double(self.export?.progress ?? 0)) / Double(count)
            }
        }
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        progressTimer?.invalidate(); progressTimer = nil; export = nil
        return session.status == .completed
    }

    private func exportFFmpeg(_ url: URL, to output: URL, format: String, quality: VideoQuality, index: Int, count: Int) async -> Bool {
        guard let executable = Self.ffmpegURL else { return false }
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        guard !cancelled else { return false }
        let task = Process(), progressPipe = Pipe()
        task.executableURL = executable
        let crf = quality == .high ? "18" : quality == .balanced ? "22" : "26"
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", url.path, "-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p"]
        if quality != .high {
            let edge = quality == .balanced ? 1920 : 1280
            arguments += ["-vf", "scale=w='min(iw,\(edge))':h='min(ih,\(edge))':force_original_aspect_ratio=decrease:force_divisible_by=2"]
        } else { arguments += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"] }
        arguments += ["-c:a", "aac", "-b:a", "192k", "-progress", "pipe:1", "-nostats"]
        if format != "MKV" { arguments += ["-movflags", "+faststart"] }
        arguments += [output.path]
        task.arguments = arguments
        task.standardOutput = progressPipe
        task.standardError = FileHandle.nullDevice
        let reader = FFmpegProgressReader()
        progressPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, duration.isFinite, duration > 0, let seconds = reader.read(data) else { return }
            Task { @MainActor in self?.progress = (Double(index) + min(0.99, seconds / duration)) / Double(count) }
        }
        process = task
        let success: Bool = await withCheckedContinuation { continuation in
            task.terminationHandler = { task in continuation.resume(returning: task.terminationStatus == 0) }
            do { try task.run() }
            catch { task.terminationHandler = nil; continuation.resume(returning: false) }
        }
        progressPipe.fileHandleForReading.readabilityHandler = nil
        process = nil
        return success
    }

    nonisolated static func uniqueOutput(in folder: URL, stem: String, suffix: String) -> URL {
        var index = 1
        var url = folder.appendingPathComponent("\(stem).\(suffix)")
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = folder.appendingPathComponent("\(stem) \(index).\(suffix)")
        }
        return url
    }
}

@MainActor
final class AirDropSender: NSObject, NSSharingServiceDelegate {
    private var service: NSSharingService?
    var finished: ((String?) -> Void)?

    func send(_ urls: [URL]) -> Bool {
        guard service == nil, !urls.isEmpty,
              urls.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }),
              let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return false }
        self.service = service
        service.delegate = self
        service.perform(withItems: urls)
        return true
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        service = nil
        finished?(nil)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        service = nil
        let cancelled = (error as NSError).code == NSUserCancelledError
        finished?(cancelled ? nil : "AirDrop: \(error.localizedDescription)")
    }
}
