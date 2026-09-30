import AppKit
import SwiftUI

@main @MainActor enum Screenshots {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("Touch-screenshots-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let pdf = fixtures.appendingPathComponent("Бриф.pdf"), zip = fixtures.appendingPathComponent("Материалы.zip")
        try Data("Touch review fixture".utf8).write(to: pdf); try Data().write(to: zip)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let clipboard = ClipboardStore(board: board)
        board.setString("Встреча в пятницу, 15:00. Обсудить макеты и собрать обратную связь.", forType: .string); clipboard.poll(userInitiated: true)
        let capturesFolder = fixtures.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        let model = AppModel(clipboard: clipboard, captures: CaptureStore(folder: capturesFolder), shelf: FileShelfStore(defaults: nil))
        model.english = false; model.availableWidth = 984; model.expanded = true; model.notchWidth = 179; model.notchHeight = 32
        // Fixtures are never written to the user's shelf or playback state.
        model.shelf.add([pdf, zip])
        model.music.isFixture = true; model.music.connected = true; model.music.permissionNeeded = false
        model.music.playing = true
        model.music.title = "Общество Мертвых Поэтов"; model.music.artist = "VILLIAN, Aarne"
        model.music.elapsed = 80; model.music.duration = 126
        // Album artwork matching the supplied music screenshot.
        let artworkURL = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/1f/72/90/1f729078-0a21-ede0-5246-f501f51a7339/cover.jpg/600x600bb.jpg")!
        let artworkSource = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : artworkURL
        guard let cover = NSImage(data: try Data(contentsOf: artworkSource)) else { fatalError("Album artwork unavailable") }
        model.music.artwork = cover
        model.music.recordCurrentTrack()
        if let data = cover.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            let url = fixtures.appendingPathComponent("Обложка.png")
            try png.write(to: url); model.shelf.add([url])
        }
        for index in 0..<8 {
            let preview = ImageRenderer(content:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.45)).frame(width: 7, height: 7) }; Spacer() }
                    Text(["Новый проект", "Цвет и форма", "Идеи", "Материалы"][index % 4]).font(.system(size: 22, weight: .bold))
                    HStack(spacing: 10) { ForEach(0..<3) { item in RoundedRectangle(cornerRadius: 10).fill(Color(hue: Double(index + item) / 11, saturation: 0.65, brightness: 0.8)).frame(height: 76) } }
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.3)).frame(width: 160, height: 6)
                }.padding(22).frame(width: 360, height: 210).background(Color(white: 0.09)).foregroundStyle(.white))
            if let data = preview.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                try png.write(to: capturesFolder.appendingPathComponent("Макет-\(index + 1).png"))
            }
        }
        model.captures.refresh()
        model.shelf.selected = []
        for (name, tab) in [("home", HubTab.overview), ("music", .music), ("captures", .captures), ("files", .files)] {
            model.tab = tab
            let view = WidePanel(model: model).clipShape(NotchShape(radius: 26))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: model.panelWidth, height: model.panelHeight)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            if tab == .files {
                func findCanvas(_ view: NSView) -> MarqueeCanvas? {
                    if let canvas = view as? MarqueeCanvas { return canvas }
                    return view.subviews.compactMap { findCanvas($0) }.first
                }
                if let canvas = findCanvas(host) {
                    canvas.beginMarquee(at: NSPoint(x: 0, y: 0))
                    canvas.moveMarquee(to: NSPoint(x: 230, y: 105))
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    host.layoutSubtreeIfNeeded()
                }
            }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(model.panelWidth * 2), pixelsHigh: Int(model.panelHeight * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render \(name)") }
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        print("Saved interface screenshots with demo data")
    }
}
