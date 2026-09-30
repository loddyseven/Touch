import AppKit

private final class RecordingSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor final class RecordingRegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((RecordingTarget?) -> Void)?
    private var screenObserver: NSObjectProtocol?

    func select(completion: @escaping (RecordingTarget?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let window = RecordingSelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.title = "Выбери область записи · Esc — отмена"
            let view = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size)) { [weak self] rect in
                guard let rect, let crop = RecordingTarget.sourceRect(selection: rect, screenSize: screen.frame.size) else {
                    self?.finish(nil); return
                }
                self?.finish(RecordingTarget(displayID: RecordingTarget.screen(screen).displayID, sourceRect: crop))
            }
            window.contentView = view; window.makeFirstResponder(view)
            windows.append(window); window.orderFrontRegardless()
            if screen.frame.contains(NSEvent.mouseLocation) { window.makeKey() }
        }
        NSApp.activate(ignoringOtherApps: true)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() { finish(nil) }
    private func finish(_ target: RecordingTarget?) {
        guard let completion else { return }
        self.completion = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll()
        completion(target)
    }
}

private final class RecordingSelectionView: NSView {
    private var origin: CGPoint?
    private var selection: CGRect = .zero
    private let completed: (CGRect?) -> Void
    init(frame: CGRect, completed: @escaping (CGRect?) -> Void) {
        self.completed = completed; super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Выдели область для записи. Escape — отмена.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); origin = convert(event.locationInWindow, from: nil); selection = .zero; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y), width: abs(current.x - origin.x), height: abs(current.y - origin.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 24, selection.height >= 24 else { origin = nil; needsDisplay = true; return }
        completed(selection)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { completed(nil) } else { super.keyDown(with: event) } }
    override func draw(_ dirtyRect: NSRect) {
        let veil = NSBezierPath(rect: bounds)
        if selection.width > 0 { veil.appendRect(selection) }
        veil.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill(); veil.fill()
        if selection.width > 0 {
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.setStroke(); outline.lineWidth = 1.5; outline.stroke()
            for point in [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)] {
                NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), xRadius: 2, yRadius: 2).fill()
            }
        }
        let text = origin == nil ? "Выдели область  ·  Esc — отмена" : "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: (bounds.width - size.width - 32) / 2, y: bounds.height - 104, width: size.width + 32, height: 38)
        NSColor(white: 0.08, alpha: 1).setFill(); NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.midY - size.height / 2), withAttributes: attributes)
    }
}
