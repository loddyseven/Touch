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
        let frames = 80
        let analyzer = SpectrumAnalyzer()
        var sampledLevels = [[Double]]()
        var latest = [Double](repeating: 0, count: SpectrumAnalyzer.bandCount)
        for sample in 0..<(48000 * 4) {
            let time = Double(sample) / 48000
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            let frequency = [52.0, 85, 65, 95][Int(time / 0.5) % 4]
            let angle = 2 * Double.pi * (frequency * phase + 65 * 0.016 * (1 - exp(-phase / 0.016)))
            let audio = time < 3.2 ? 0.35 * sin(angle) * exp(-phase / 0.075) * (1 - exp(-phase / 0.001)) : 0
            if let values = analyzer.feed(Float(audio), sampleRate: 48000) { latest = values }
            if (sample + 1) % 2400 == 0 { sampledLevels.append(latest) }
        }
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames, nil) else { fatalError("GIF destination") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            // A short pause demonstrates that the music notch stays visible.
            model.music.playing = frame < 64
            model.music.spectrum.previewLevels(sampledLevels[frame])
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 320,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { fatalError("Frame") }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
            if frame == 21 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("music-notch.png"))
            }
        }
        guard CGImageDestinationFinalize(destination) else { fatalError("GIF export") }
        print("Rendered the collapsed music notch with analyzed synthetic bass and a pause")
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
