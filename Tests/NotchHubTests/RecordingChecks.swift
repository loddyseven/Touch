import AppKit
import AVFoundation

@MainActor final class FakeRecordingSession: RecordingSessionProtocol {
    var started: (() -> Void)?
    var interrupted: ((Error) -> Void)?
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
    var stopError: Error?
    var finishDelay: Duration = .zero
    var delayFileUntilFinish = false
    var signalsFinish = true
    var signalsFinishBeforeFile = false
    func start(target: RecordingTarget, audio: Bool, output: URL) async throws {
        starts += 1; self.audio = audio; self.output = output
        if let startError { throw startError }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let movie, !delayFileUntilFinish { try FileManager.default.copyItem(at: movie, to: output) }
        else { try Data().write(to: output) }
        if signalsStart { started?() }
    }
    func stop() async throws {
        stops += 1
        guard stops == 1 else { return }
        if let stopError { interrupted?(stopError) }
        if finishDelay == .zero, signalsFinish { finished?(finishError) }
        else if signalsFinish {
            if signalsFinishBeforeFile { finished?(finishError) }
            Task { @MainActor in
                try? await Task.sleep(for: finishDelay)
                if delayFileUntilFinish, let movie, let output { try? Data(contentsOf: movie).write(to: output) }
                if !signalsFinishBeforeFile { finished?(finishError) }
            }
        }
        if let stopError { throw stopError }
    }
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
        // A silent 36-second movie reproduces the reported duration without
        // requiring a live capture or waiting 36 seconds in every test run.
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index * 2), timescale: 1)) else { throw writer.error! }
    }
    input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 36, timescale: 1)); writer.finishWriting { }
    guard wait({ writer.status == .completed || writer.status == .failed }), writer.status == .completed else { throw writer.error ?? ScreenRecorder.RecordingError.empty }
    var fixtureDuration = 0.0
    Task { @MainActor in fixtureDuration = (try? await AVURLAsset(url: fixture).load(.duration).seconds) ?? 0 }
    check(wait { fixtureDuration > 0 } && abs(fixtureDuration - 36) < 0.1, "The recording regression fixture contains 36 seconds of video without audio")

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

    let lateBackend = FakeRecordingSession(); lateBackend.movie = fixture
    lateBackend.delayFileUntilFinish = true; lateBackend.finishDelay = .milliseconds(400)
    lateBackend.stopError = NSError(domain: "SCStreamErrorDomain", code: -3817)
    let late = ScreenRecorder(folder: root.appendingPathComponent("Delayed writer"), countdownInterval: .milliseconds(1), makeSession: { lateBackend })
    var lateSaved: [URL] = []; late.saved = { lateSaved.append($0) }
    late.begin(target: target); _ = wait { late.phase == .recording }; late.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    check(late.phase == .finishing && lateSaved.isEmpty && late.message == nil, "Stream-stop errors cannot validate or discard an MP4 before the writer finishes")
    check(wait { late.phase == .idle && lateSaved.count == 1 } && !lateBackend.audio, "A delayed silent 36-second recording is saved after its output callback")

    let flushBackend = FakeRecordingSession(); flushBackend.movie = fixture
    flushBackend.delayFileUntilFinish = true; flushBackend.finishDelay = .milliseconds(400); flushBackend.signalsFinishBeforeFile = true
    let flushed = ScreenRecorder(folder: root.appendingPathComponent("Delayed footer"), countdownInterval: .milliseconds(1), makeSession: { flushBackend })
    var flushSaved = false; flushed.saved = { _ in flushSaved = true }
    flushed.begin(target: target); _ = wait { flushed.phase == .recording }; flushed.stop()
    check(wait { flushed.phase == .idle && flushSaved }, "Transient Cannot Open during footer publication retries with a fresh asset")

    let interruptedWriter = FakeRecordingSession(); interruptedWriter.movie = fixture
    let streamFailure = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { interruptedWriter })
    var streamSaved = 0; streamFailure.saved = { _ in streamSaved += 1 }
    streamFailure.begin(target: target); _ = wait { streamFailure.phase == .recording }
    interruptedWriter.interrupted?(ScreenRecorder.RecordingError.displayMissing)
    check(streamFailure.phase == .finishing && streamSaved == 0, "An external stream interruption waits for the recording-output delegate")
    interruptedWriter.finished?(nil); interruptedWriter.finished?(nil)
    check(wait { streamFailure.phase == .idle && streamSaved == 1 }, "Duplicate output callbacks save an interrupted movie exactly once")

    let failedBackend = FakeRecordingSession(); failedBackend.startError = ScreenRecorder.RecordingError.displayMissing
    let failed = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), makeSession: { failedBackend })
    failed.begin(target: target)
    check(wait { failed.phase == .idle && failed.message != nil }, "Capture-start errors return controls to an actionable state")
    check(CaptureStore(folder: folder).items.count == 2, "A failed recording does not remove previously saved videos")

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

    let strandedBackend = FakeRecordingSession(); strandedBackend.movie = fixture; strandedBackend.signalsFinish = false
    let stranded = ScreenRecorder(folder: folder, countdownInterval: .milliseconds(1), completionTimeout: .milliseconds(100), makeSession: { strandedBackend })
    stranded.begin(target: target); _ = wait { stranded.phase == .recording }; stranded.stop()
    check(wait { stranded.phase == .idle && stranded.message != nil } && stranded.recoveryURL == strandedBackend.output, "A missing output callback leaves an accessible recovery file")
    let details = stranded.failureDetailsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    check(details?.contains("System audio: false") == true && details?.contains("Capture:") == true, "Recording failures retain local OS, audio mode, and error-code diagnostics")
    let relaunched = ScreenRecorder(folder: folder, makeSession: { FakeRecordingSession() })
    check(relaunched.recoveryURL != nil, "Unfinished recordings remain discoverable after relaunch")

}
