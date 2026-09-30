import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Compile with -DTOUCH_SCREENSHOT_FIXTURES. Audio is never captured by this renderer.
@main @MainActor enum NotchScreenshot {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cover = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Touch-notch-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let model = AppModel(clipboard: ClipboardStore(board: board), captures: CaptureStore(folder: folder), shelf: FileShelfStore(defaults: nil))
        model.music.isFixture = true; model.music.spectrum.isFixture = true
        model.expanded = false; model.notchWidth = 179; model.notchHeight = 32
        model.music.connected = true; model.music.playing = true
        model.music.title = "Общество Мертвых Поэтов"; model.music.artist = "VILLIAN, Aarne"
        model.music.artwork = NSImage(contentsOf: cover)
        model.music.duration = 126; model.music.elapsed = 80
        let stage = NotchStage(model: model)
        let host = NSHostingView(rootView: stage)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let gif = output.appendingPathComponent("music-notch.gif")
        let frames = 48
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames, nil) else { fatalError("GIF destination") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            // A short pause demonstrates that the music notch stays visible.
            model.music.playing = frame < 34
            model.music.spectrum.previewLevels((0..<5).map { band in
                let wave = sin(Double(frame) * 0.69 + Double(band) * 1.8)
                return 0.2 + 0.72 * abs(wave)
            })
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 320,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { fatalError("Frame") }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            if frame == 12 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("music-notch.png"))
            }
        }
        guard CGImageDestinationFinalize(destination) else { fatalError("GIF export") }
        print("Rendered the collapsed music notch with preview spectrum levels")
    }
}

private struct NotchStage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var music: MusicController
    init(model: AppModel) { self.model = model; music = model.music }
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.15, green: 0.17, blue: 0.21), Color(red: 0.07, green: 0.08, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HubView(model: model)
                .frame(width: model.collapsedWidth, height: model.notchHeight + 1)
                .scaleEffect(2, anchor: .top)
                .frame(width: model.collapsedWidth * 2, height: (model.notchHeight + 1) * 2, alignment: .top)
            VStack(spacing: 6) {
                Text(music.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Text("\(music.artist) · \(music.playing ? "Играет" : "Пауза")")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }.padding(.top, 99)
        }.frame(width: 720, height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
