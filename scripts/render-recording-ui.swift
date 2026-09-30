import AppKit
import SwiftUI

@main @MainActor enum RecordingReview {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = output.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let fake = FakeRecordingSession()
        let recorder = ScreenRecorder(folder: fixtures, countdownInterval: .milliseconds(150), makeSession: { fake })
        let model = AppModel(clipboard: ClipboardStore(board: board), captures: CaptureStore(folder: fixtures), shelf: FileShelfStore(defaults: nil), recorder: recorder)
        model.english = false; model.expanded = true; model.notchWidth = 179; model.notchHeight = 32; model.tab = .captures
        model.music.isFixture = true
        recorder.showsSetup = true
        func render(_ name: String, compact: Bool = false) throws {
            let host = NSHostingView(rootView: HubView(model: model))
            host.frame = CGRect(x: 0, y: 0, width: compact ? model.collapsedWidth : model.panelWidth, height: compact ? model.notchHeight + 1 : model.panelHeight)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        try render("recording-setup")
        recorder.mode = .region; recorder.capturesAudio = true
        try render("recording-region")
        recorder.begin(target: RecordingTarget(displayID: 1, sourceRect: nil))
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        try render("recording-active")
        model.expanded = false
        try render("recording-notch", compact: true)
        recorder.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        print("Rendered native screen recording controls")
    }
}
