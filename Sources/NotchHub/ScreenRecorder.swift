import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

enum RecordingPhase: Equatable {
    case idle, selecting, countdown(Int), preparing, recording, finishing
    var isBusy: Bool { self != .idle }
    var canStop: Bool {
        switch self { case .countdown, .recording: return true; default: return false }
    }
}

struct RecordingTarget: Equatable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect?

    static func sourceRect(selection: CGRect, screenSize: CGSize) -> CGRect? {
        let rect = selection.standardized.intersection(CGRect(origin: .zero, size: screenSize))
        guard !rect.isNull, rect.width >= 24, rect.height >= 24 else { return nil }
        return CGRect(x: rect.minX, y: screenSize.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func outputSize(points: CGSize, scale: CGFloat) -> CGSize {
        let width = max(2, points.width * scale), height = max(2, points.height * scale)
        let fit = min(1, min(3840 / width, 2160 / height))
        return CGSize(width: max(2, floor(width * fit / 2) * 2), height: max(2, floor(height * fit / 2) * 2))
    }

    static func screen(_ screen: NSScreen) -> RecordingTarget {
        RecordingTarget(displayID: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID(), sourceRect: nil)
    }
}

@MainActor protocol RecordingSessionProtocol: AnyObject {
    var started: (() -> Void)? { get set }
    var finished: ((Error?) -> Void)? { get set }
    func start(target: RecordingTarget, audio: Bool, output: URL) async throws
    func stop() async throws
}

@MainActor
final class ScreenRecorder: ObservableObject {
    enum Mode: String, CaseIterable { case screen, region }
    @Published var mode: Mode = .screen
    @Published var capturesAudio = false
    @Published var showsSetup = false
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var message: String?
    @Published private(set) var needsPermission = false
    var beforeSelection: (() -> Void)?
    var afterSelection: ((Bool) -> Void)?
    var countdownBegan: (() -> Void)?
    var saved: ((URL) -> Void)?
    var becameIdle: (() -> Void)?
    private let folder: URL
    private let makeSession: @MainActor () throws -> any RecordingSessionProtocol
    private let countdownInterval: Duration
    private let completionTimeout: Duration
    private var watchdog: Task<Void, Never>?
    private var isFinalizing = false
    private var session: (any RecordingSessionProtocol)?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var operationID: UUID?
    private var temporaryURL: URL?
    private var outputURL: URL?
    private var selector: RecordingRegionSelector?
    private var startedAt: TimeInterval = 0
    private var stopWhenStarted = false

    init(folder: URL, countdownInterval: Duration = .seconds(1), completionTimeout: Duration = .seconds(20),
         makeSession: @escaping @MainActor () throws -> any RecordingSessionProtocol = {
             guard #available(macOS 15, *) else { throw RecordingError.unsupported }
             return ScreenCaptureSession()
         }) {
        self.folder = folder; self.makeSession = makeSession; self.countdownInterval = countdownInterval; self.completionTimeout = completionTimeout
    }

    var clock: String {
        let seconds = Int(max(0, elapsed))
        return seconds < 3600 ? String(format: "%02d:%02d", seconds / 60, seconds % 60)
            : String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    func request() {
        guard !phase.isBusy else { return }
        needsPermission = false; message = nil
        guard #available(macOS 15, *) else { message = RecordingError.unsupported.localizedDescription; return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            needsPermission = true; message = "Разреши Touch запись экрана в настройках macOS."; return
        }
        if mode == .region {
            phase = .selecting; beforeSelection?()
            let selector = RecordingRegionSelector()
            self.selector = selector
            selector.select { [weak self] target in
                guard let self else { return }
                self.selector = nil; self.phase = .idle
                self.afterSelection?(target != nil)
                if let target { self.begin(target: target) }
            }
        } else if let screen = MacHardware.preferredScreen() {
            begin(target: .screen(screen))
        } else { message = "Не найден экран для записи." }
    }

    func begin(target: RecordingTarget) {
        guard !phase.isBusy else { return }
        let id = UUID(); operationID = id
        elapsed = 0; message = nil
        let audio = capturesAudio
        phase = .countdown(3); countdownBegan?()
        task = Task { [weak self] in
            guard let self, self.operationID == id, !Task.isCancelled else { return }
            do {
                for value in (1...3).reversed() {
                    self.phase = .countdown(value)
                    try await Task.sleep(for: self.countdownInterval)
                }
                try Task.checkCancellation()
                self.phase = .preparing
                self.armWatchdog(id: id)
                try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let url = self.folder.appendingPathComponent("Запись \(stamp.string(from: Date())) \(id.uuidString.prefix(4)).mp4")
                let temporary = self.folder.appendingPathComponent(".Recording-\(id).mp4")
                self.outputURL = url; self.temporaryURL = temporary
                let session = try self.makeSession()
                self.session = session
                session.started = { [weak self] in
                    guard let self, self.operationID == id, self.phase == .preparing else { return }
                    self.watchdog?.cancel(); self.watchdog = nil
                    self.phase = .recording
                    self.startedAt = ProcessInfo.processInfo.systemUptime
                    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.phase == .recording else { return }
                            self.elapsed = ProcessInfo.processInfo.systemUptime - self.startedAt
                        }
                    }
                    self.timer = timer; RunLoop.main.add(timer, forMode: .common)
                    if self.stopWhenStarted { self.stop() }
                }
                session.finished = { [weak self] error in
                    guard let self, self.operationID == id else { return }
                    Task { @MainActor in await self.finish(error: error, id: id) }
                }
                try await session.start(target: target, audio: audio, output: temporary)
            } catch is CancellationError { }
            catch { await self.fail(error, id: id) }
        }
    }

    func stop() {
        switch phase {
        case .countdown:
            task?.cancel(); task = nil; reset(); becameIdle?()
        case .selecting:
            selector?.cancel()
        case .recording:
            phase = .finishing; timer?.invalidate(); timer = nil
            guard let id = operationID, let session else { return }
            armWatchdog(id: id)
            task = Task { [weak self] in
                do { try await session.stop() }
                catch { await self?.finish(error: error, id: id) }
            }
        case .preparing: stopWhenStarted = true
        default: break
        }
    }

    private func finish(error: Error?, id: UUID) async {
        guard operationID == id, !isFinalizing, let temporaryURL, let outputURL else { return }
        isFinalizing = true
        watchdog?.cancel(); watchdog = nil
        phase = .finishing; timer?.invalidate(); timer = nil
        do {
            let asset = AVURLAsset(url: temporaryURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration).seconds
            guard !tracks.isEmpty, duration.isFinite, duration > 0 else { throw RecordingError.empty }
            guard operationID == id else { return }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            reset(); showsSetup = false
            message = error == nil ? nil : "Запись прервана. Доступная часть видео сохранена."
            saved?(outputURL); becameIdle?()
        } catch { await fail(error, id: id) }
    }

    private func fail(_ error: Error, id: UUID) async {
        guard operationID == id else { return }
        let current = session, unfinished = temporaryURL
        reset()
        current?.started = nil; current?.finished = nil
        // Do not block exit if the framework stops responding. Preserve nonempty
        // unfinished output so an interrupted capture is never silently deleted.
        Task { try? await current?.stop() }
        if let unfinished, (try? unfinished.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
            try? FileManager.default.removeItem(at: unfinished)
        }
        message = "Не удалось сохранить запись. \(error.localizedDescription)"
        becameIdle?()
    }

    private func armWatchdog(id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.completionTimeout) } catch { return }
            guard self.operationID == id else { return }
            self.task?.cancel()
            await self.fail(RecordingError.timeout, id: id)
        }
    }

    private func reset() {
        watchdog?.cancel(); watchdog = nil; isFinalizing = false
        timer?.invalidate(); timer = nil
        session?.started = nil; session?.finished = nil
        session = nil; task = nil; operationID = nil; temporaryURL = nil; outputURL = nil
        phase = .idle
        stopWhenStarted = false
    }

    enum RecordingError: LocalizedError {
        case unsupported, displayMissing, empty, timeout
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Для записи экрана нужна macOS 15 или новее."
            case .displayMissing: return "Выбранный экран отключён. Выбери его заново."
            case .timeout: return "Система записи не ответила. Попробуй ещё раз."
            case .empty: return "Видео не содержит кадров. Попробуй записать ещё раз."
            }
        }
    }
}

@available(macOS 15, *)
@MainActor private final class ScreenCaptureSession: NSObject, RecordingSessionProtocol, SCStreamDelegate, SCRecordingOutputDelegate {
    var started: (() -> Void)?
    var finished: ((Error?) -> Void)?
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var didFinish = false

    func start(target: RecordingTarget, audio: Bool, output: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw ScreenRecorder.RecordingError.displayMissing
        }
        let filter = SCContentFilter(display: display,
            excludingApplications: content.applications.filter { $0.processID == getpid() }, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let rect = target.sourceRect ?? CGRect(origin: .zero, size: filter.contentRect.size)
        let size = RecordingTarget.outputSize(points: rect.size, scale: CGFloat(filter.pointPixelScale))
        config.width = Int(size.width); config.height = Int(size.height)
        if target.sourceRect != nil { config.sourceRect = rect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5; config.showsCursor = true
        config.capturesAudio = audio; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = output; outputConfig.videoCodecType = .h264; outputConfig.outputFileType = .mp4
        let recording = SCRecordingOutput(configuration: outputConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream; self.recording = recording
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
    }

    func stop() async throws { if let stream { try await stream.stopCapture() } }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.started?() }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.complete(nil) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.complete(error) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.complete(error) }
    }
    private func complete(_ error: Error?) {
        guard !didFinish else { return }; didFinish = true
        finished?(error)
    }
}
