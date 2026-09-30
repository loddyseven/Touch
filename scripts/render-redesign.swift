import AppKit
import SwiftUI

@main @MainActor enum RedesignReview {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = output.appendingPathComponent("fixture-files")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let pdf = fixtures.appendingPathComponent("Project.pdf"), zip = fixtures.appendingPathComponent("Assets.zip")
        try Data("Touch review fixture".utf8).write(to: pdf); try Data().write(to: zip)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let clipboard = ClipboardStore(board: board)
        board.setString("Make room for what matters.", forType: .string); clipboard.poll(userInitiated: true)
        let model = AppModel(clipboard: clipboard, captures: CaptureStore(folder: fixtures), shelf: FileShelfStore(defaults: nil))
        model.english = true; model.expanded = true; model.notchWidth = 179; model.notchHeight = 32
        // Fixtures are never written to the user's shelf or playback state.
        model.shelf.add([pdf, zip])
        model.music.isFixture = true; model.music.connected = true; model.music.permissionNeeded = false
        model.music.playing = true; model.music.title = "Night Drive"; model.music.artist = "Touch Sessions"
        model.music.elapsed = 43; model.music.duration = 195
        let cover = ImageRenderer(content:
            LinearGradient(colors: [Color(red: 0.11, green: 0.08, blue: 0.28), Color(red: 0.68, green: 0.26, blue: 0.59), Color(red: 1, green: 0.6, blue: 0.39)], startPoint: .top, endPoint: .bottomTrailing)
                .frame(width: 320, height: 320)
                .overlay(alignment: .topTrailing) { Circle().fill(Color(red: 1, green: 0.72, blue: 0.39)).frame(width: 135, height: 135).padding(35) }
                .overlay(alignment: .bottom) { Ellipse().fill(Color(red: 0.08, green: 0.09, blue: 0.24)).frame(width: 510, height: 235).rotationEffect(.degrees(-24)).offset(x: -45, y: 90) }
                .overlay(alignment: .bottomLeading) { VStack(alignment: .leading, spacing: -6) { Text("NIGHT"); Text("DRIVE") }.font(.system(size: 45, weight: .black)).foregroundStyle(.white).padding(24) }.clipped())
        cover.scale = 2; model.music.artwork = cover.nsImage
        if let data = model.music.artwork?.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent("redesign-cover.png")) }
        for (name, tab) in [("home", HubTab.overview), ("files", .files), ("captures", .captures), ("music", .music), ("formats", .converter), ("clipboard", .clipboard), ("apps", .apps)] {
            if tab == .captures {
                try Data(contentsOf: output.appendingPathComponent("redesign-home.png")).write(to: fixtures.appendingPathComponent("Capture.png"))
                model.captures.refresh(); model.captures.selectAll()
            }
            model.tab = tab
            let view = WidePanel(model: model).clipShape(NotchShape(radius: 26))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: model.panelWidth, height: model.panelHeight)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(model.panelWidth * 3), pixelsHigh: Int(model.panelHeight * 3), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render \(name)") }
            try png.write(to: output.appendingPathComponent("redesign-\(name).png"))
        }
        print("Saved native redesign review frames")
    }
}
