import AppKit
import SwiftUI

@main
@MainActor
enum SetupReview {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let screen = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let notched = MacDisplay(name: "Built-in Liquid Retina Display", frame: screen, topInset: 32,
            left: NSRect(x: 0, y: 924, width: 643, height: 32), right: NSRect(x: 827, y: 924, width: 643, height: 32))
        let plain = MacDisplay(name: "External Display", frame: screen, topInset: 0, left: nil, right: nil)
        let fixtures: [(String, MacSetup.Stage, MacFamily, MacSnapshot, MacVerification)] = [
            ("choose", .choose, .pro14, MacSnapshot(identifier: "Mac14,2", display: notched), .unrecognized),
            ("selected", .choose, .air13, MacSnapshot(identifier: "Mac14,2", display: notched), .unrecognized),
            ("checking", .checking, .air13, MacSnapshot(identifier: "Mac14,2", display: notched), .unrecognized),
            ("ready", .result, .air13, MacSnapshot(identifier: "Mac14,2", display: notched), .confirmed),
            ("compact", .result, .pro13, MacSnapshot(identifier: "MacBookPro17,1", display: plain), .confirmed),
            ("mismatch", .result, .pro16, MacSnapshot(identifier: "Mac14,2", display: notched), .mismatch),
            ("unknown", .result, .other, MacSnapshot(identifier: "Mac99,999", display: notched), .unrecognized)
        ]
        for english in [false, true] {
            for (name, stage, selected, snapshot, verification) in fixtures {
                let view = MacSetupSurface(stage: stage, selected: selected, snapshot: snapshot, verification: verification, english: english)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to render \(name)") }
                try png.write(to: output.appendingPathComponent("setup-\(english ? "en" : "ru")-\(name).png"))
            }
        }
        // Isolated empty stores: the film never reads the user's clipboard or captures.
        let fixtureFolder = output.appendingPathComponent("empty-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        let model = AppModel(clipboard: ClipboardStore(board: NSPasteboard(name: .init("Touch.SetupFilm"))), captures: CaptureStore(folder: fixtureFolder))
        let home = HomePage(model: model, captures: model.captures, clipboard: model.clipboard, audio: model.audio)
            .buttonStyle(.plain).preferredColorScheme(.dark).tint(.white).foregroundStyle(.white).font(.system(size: 11))
            .background(Color(white: 0.006))
        // AppKit-backed controls (the volume slider) need NSView bitmap caching.
        let host = NSHostingView(rootView: home)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 258)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            // Keep SwiftUI text at 4× resolution; composite only the native control band.
            let renderer = ImageRenderer(content: home)
            renderer.scale = 4
            guard let sharp = renderer.nsImage else { fatalError("Home render failed") }
            let final = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1120, pixelsHigh: 1032,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 1120 * 4, bitsPerPixel: 32)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: final)
            let bounds = NSRect(x: 0, y: 0, width: 1120, height: 1032)
            sharp.draw(in: bounds)
            NSBezierPath(rect: NSRect(x: 0, y: (258 - 234) * 4, width: 1120, height: 23 * 4)).addClip()
            let controls = NSImage(size: NSSize(width: 280, height: 258))
            controls.addRepresentation(rep)
            controls.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = final.representation(using: .png, properties: [:]) else { fatalError("Home render failed") }
            try png.write(to: output.appendingPathComponent("setup-home.png"))
        }
        print("14 native first-launch frames and the native home view saved")
        let actual = MacHardware.read()
        print("Detected: \(actual.identifier), \(actual.display?.name ?? "no display"), notch: \(actual.display?.hasNotch ?? false)")
        if let geometry = actual.display?.geometry { print("Actual panel geometry: \(geometry.notchWidth) × \(geometry.notchHeight) pt") }
    }
}
