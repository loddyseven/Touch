import AppKit
import AVFoundation

@MainActor final class FakeRecordingSession: RecordingSessionProtocol {
    var started: (() -> Void)?
    var finished: ((Error?) -> Void)?
    var output: URL?
    var starts = 0
    var stops = 0
    var audio = false
    var startError: Error?
    var delay: Duration = .zero
    var movie: URL?
    var signalsStart = true
    var finishError: Error?
    func start(target: RecordingTarget, audio: Bool, output: URL) async throws {
        starts += 1; self.audio = audio; self.output = output
        if let startError { throw startError }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let movie { try FileManager.default.copyItem(at: movie, to: output) }
        else { try Data().write(to: output) }
        if signalsStart { started?() }
    }
    func stop() async throws { stops += 1; finished?(finishError) }
}

@MainActor func recordingChecks(check: (Bool, String) -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Touch-recording-checks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    let size = CGSize(width: 800, height: 600)
    check(RecordingTarget.sourceRect(selection: CGRect(x: 100, y: 50, width: 200, height: 100), screenSize: size) == CGRect(x: 100, y: 450, width: 200, height: 100), "Screen recording crop converts AppKit's bottom origin to display coordinates")
    check(RecordingTarget.sourceRect(selection: CGRect(x: -20, y: 40, width: 100, height: 100), screenSize: size)?.minX == 0, "Recording region stays inside the selected display")
    check(RecordingTarget.sourceRect(selection: CGRect(x: 0, y: 0, width: 10, height: 10), screenSize: size) == nil, "Accidental tiny selections do not start recording")
    let pixels = RecordingTarget.outputSize(points: CGSize(width: 3001, height: 2001), scale: 2)
    check(pixels.width <= 3840 && pixels.height <= 2160 && Int(pixels.width) % 2 == 0 && Int(pixels.height) % 2 == 0, "Retina recordings use bounded even encoder dimensions")

    let fixture = root.appendingPathComponent("Fixture.mp4")
    let writer = try AVAssetWriter(outputURL: fixture, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<18 {
        guard wait({ input.isReadyForMoreMediaData }) else { throw ScreenRecorder.RecordingError.empty }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else { throw ScreenRecorder.RecordingError.empty }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(90 + index * 5), CVPixelBufferGetBytesPerRow(buffer) * 96)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error! }
    }
    input.markAsFinished(); writer.finishWriting { }
    guard wait({ writer.status == .completed || writer.status == .failed }), writer.status == .completed else { throw writer.error ?? ScreenRecorder.RecordingError.empty }

    let target = RecordingTarget(displayID: 1, sourceRect: nil)
    let cancelledBackend = FakeRecordingSession()
    let cancelled = ScreenRecorder(folder: root.appendingPathComponent("Cancelled"), makeSession: { cancelledBackend })
    cancelled.begin(target: target); cancelled.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(cancelled.phase == .idle && cancelledBackend.starts == 0, "Cancelling the countdown never starts capture or creates a recording")

    let folder = root.appendingPathComponent("Saved")
    let backend = FakeRecordingSession(); backend.movie = fixture
    let recorder = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { backend })
    recorder.capturesAudio = true
    var saved: [URL] = []
    recorder.saved = { saved.append($0) }
    recorder.begin(target: target); recorder.begin(target: target)
    check(wait { recorder.phase == .recording } && backend.starts == 1, "Recording starts once after countdown; repeated start cannot create parallel sessions")
    check(backend.audio, "System audio follows the explicit toggle")
    check(CaptureStore(folder: folder).items.isEmpty, "Unfinished video stays hidden from the capture gallery")
    recorder.stop(); recorder.stop()
    check(wait { recorder.phase == .idle && saved.count == 1 } && backend.stops == 1, "Stop finalizes exactly one playable MP4")
    let store = CaptureStore(folder: folder)
    check(store.items.count == 1 && store.items[0].isVideo, "Completed recording appears in the same gallery as screenshots")
    check(wait { store.items.first?.thumbnail != nil }, "Video preview is generated asynchronously")
    check(!FileManager.default.fileExists(atPath: backend.output!.path), "Finalizing moves the hidden temporary movie to its visible filename")

    let failedBackend = FakeRecordingSession(); failedBackend.startError = ScreenRecorder.RecordingError.displayMissing
    let failed = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { failedBackend })
    failed.begin(target: target)
    check(wait { failed.phase == .idle && failed.message != nil }, "Capture-start errors return controls to an actionable state")
    check(CaptureStore(folder: folder).items.count == 1, "A failed recording does not remove previously saved videos")

    let delayedBackend = FakeRecordingSession(); delayedBackend.movie = fixture; delayedBackend.delay = .milliseconds(150)
    let delayed = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { delayedBackend })
    var delayedSaved = false; delayed.saved = { _ in delayedSaved = true }
    delayed.begin(target: target)
    check(wait { delayed.phase == .preparing }, "Preparation has a separate state before the recording delegate starts")
    delayed.stop()
    check(wait { delayed.phase == .idle && delayedSaved }, "Quit during preparation waits for safe recording finalization")

    let emptyBackend = FakeRecordingSession()
    let empty = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { emptyBackend })
    empty.begin(target: target); _ = wait { empty.phase == .recording }; empty.stop()
    check(wait { empty.phase == .idle && empty.message != nil }, "Empty or invalid movies are not reported as successful recordings")
    let interruptedBackend = FakeRecordingSession(); interruptedBackend.movie = fixture
    interruptedBackend.finishError = ScreenRecorder.RecordingError.displayMissing
    let interrupted = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { interruptedBackend })
    var recovered: URL?
    interrupted.saved = { recovered = $0 }
    interrupted.begin(target: target); _ = wait { interrupted.phase == .recording }; interrupted.stop()
    check(wait { interrupted.phase == .idle && recovered != nil } && interrupted.message != nil, "A runtime failure preserves the playable part of an interrupted recording")

    let silentBackend = FakeRecordingSession(); silentBackend.movie = fixture; silentBackend.signalsStart = false
    let timedOut = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), completionTimeout: .milliseconds(100), makeSession: { silentBackend })
    var timeoutReported = false; timedOut.becameIdle = { timeoutReported = true }
    timedOut.begin(target: target)
    check(wait { timedOut.phase == .idle && timeoutReported } && timedOut.message != nil, "A missing system callback cannot leave recording or app exit stuck forever")
    check(silentBackend.output.map { FileManager.default.fileExists(atPath: $0.path) } == true, "Timeout preserves a nonempty unfinished recording for recovery")

}
