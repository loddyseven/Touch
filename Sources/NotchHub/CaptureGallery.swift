import AppKit
import SwiftUI

struct CaptureGallery: NSViewRepresentable {
    @ObservedObject var store: CaptureStore
    var tileSize = NSSize(width: 80, height: 42)
    var rows = 1
    var selectionMenu: (() -> NSMenu)?

    func makeNSView(context: Context) -> CaptureScrollView {
        let scroll = CaptureScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = CaptureStripView(store: store, tileSize: tileSize, rows: rows)
        return scroll
    }

    func updateNSView(_ scroll: CaptureScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CaptureStripView else { return }
        canvas.makeSelectionMenu = selectionMenu
        canvas.update(tileSize: tileSize, rows: rows)
    }
}

final class CaptureScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? MarqueeCanvas)?.fitViewport(contentSize)
    }
    override func scrollWheel(with event: NSEvent) {
        // A mouse wheel should browse the horizontal shelf as well as a trackpad.
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let step = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
            let maximum = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
            let x = min(maximum, max(0, contentView.bounds.minX - step))
            contentView.scroll(to: NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        } else { super.scrollWheel(with: event) }
    }
}

final class CaptureStripView: MarqueeCanvas {
    private let store: CaptureStore
    private var tileSize: NSSize
    private var rows: Int
    private var tiles: [URL: CaptureTileView] = [:]

    init(store: CaptureStore, tileSize: NSSize = NSSize(width: 80, height: 42), rows: Int = 1) {
        self.store = store
        self.tileSize = tileSize
        self.rows = max(1, rows)
        super.init(frame: .zero)
        currentSelection = { [weak store] in store?.selectedIDs ?? [] }
        setSelection = { [weak store] in store?.setSelection($0) }
        selectionActivity = { [weak store] active in active ? store?.beginDrag() : store?.finishDrag() }
        copySelection = { [weak store] in store?.copySelected() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(tileSize: NSSize, rows: Int) {
        self.tileSize = tileSize
        self.rows = max(1, rows)
        let ids = Set(store.items.map(\.id))
        for id in Set(tiles.keys).subtracting(ids) {
            tiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        itemFrames = [:]
        let inset: CGFloat = rows > 1 ? 6 : 0
        for (index, capture) in store.items.enumerated() {
            let tile: CaptureTileView
            if let existing = tiles[capture.id] { tile = existing }
            else {
                tile = CaptureTileView(capture: capture, store: store)
                tiles[capture.id] = tile
                addSubview(tile)
            }
            tile.capture = capture
            tile.frame = NSRect(x: inset + CGFloat(index / self.rows) * (tileSize.width + 10),
                y: inset + CGFloat(self.rows - 1 - index % self.rows) * (tileSize.height + 10),
                width: tileSize.width, height: tileSize.height)
            itemFrames[capture.id] = tile.frame
            tile.updateSelection()
        }
        let columns = (store.items.count + self.rows - 1) / self.rows
        contentExtent = NSSize(width: max(0, CGFloat(columns) * (tileSize.width + 10) - 10 + inset * 2),
            height: CGFloat(self.rows) * (tileSize.height + 10) - 10 + inset * 2)
        fitViewport(enclosingScrollView?.contentSize ?? .zero)
        if let clip = superview as? NSClipView {
            clip.scroll(to: NSPoint(x: min(clip.bounds.minX, max(0, bounds.width - clip.bounds.width)), y: 0))
        }
    }

    func focusNeighbor(of capture: Capture, direction: Int, vertical: Bool = false, extending: Bool) {
        guard let index = store.items.firstIndex(where: { $0.id == capture.id }) else { return }
        let next = index + direction * (vertical ? 1 : rows)
        guard store.items.indices.contains(next), !vertical || next / rows == index / rows else { return }
        guard let tile = tiles[store.items[next].id] else { return }
        window?.makeFirstResponder(tile)
        if !extending { store.select(tile.capture.id) }
        tile.scrollToVisible(tile.bounds)
    }
}

final class CaptureTileView: NSView, NSDraggingSource {
    var capture: Capture
    private let store: CaptureStore
    private var downPoint = NSPoint.zero
    private var wasSelected = false
    private var additiveClick = false
    private var didDrag = false
    private var selectionProgress: CGFloat = 0
    private var selectionTarget: CGFloat = 0
    private var selectionTimer: Timer?
    private var thumbnailObserver: NSObjectProtocol?

    init(capture: Capture, store: CaptureStore) {
        self.capture = capture
        self.store = store
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(capture.isVideo ? "Видео" : "Снимок") \(capture.date.formatted(date: .abbreviated, time: .standard))")
        thumbnailObserver = NotificationCenter.default.addObserver(forName: .captureThumbnailReady, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? URL == self.capture.url else { return }
            self.needsDisplay = true
        }
        let hint = "Option-клик — выбрать несколько. Перетащи выбранные снимки вместе. Двойной клик — открыть."
        toolTip = hint
        setAccessibilityHelp(hint)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Добавить или убрать из выбора") { [weak self] in
                guard let self else { return false }
                self.store.select(self.capture.id, extending: true)
                return true
            }
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let thumbnailObserver { NotificationCenter.default.removeObserver(thumbnailObserver) } }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateSelection() {
        let selected = store.selectedIDs.contains(capture.id)
        setAccessibilityValue(selected ? "Выбран" : "Не выбран")
        let target: CGFloat = selected ? 1 : 0
        guard target != selectionTarget else { needsDisplay = true; return }
        selectionTarget = target
        selectionTimer?.invalidate()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            selectionProgress = target; needsDisplay = true; return
        }
        let origin = selectionProgress, start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) / 0.18
            self.selectionProgress = origin + (target - origin) * TouchMotion.quartic(elapsed)
            self.needsDisplay = true
            if elapsed >= 1 { timer.invalidate(); self.selectionTimer = nil }
        }
        selectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        let progress = selectionProgress
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(white: 0.10, alpha: 1).setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        if let image = capture.thumbnail {
            image.draw(in: Self.fittedRect(image.size, inside: rect.insetBy(dx: 2, dy: 2)),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        if capture.isVideo {
            let badge = CGRect(x: rect.midX - 15, y: rect.midY - 15, width: 30, height: 30)
            NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(ovalIn: badge).fill()
            NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white])))?
                .draw(in: CGRect(x: badge.midX - 5, y: badge.midY - 6, width: 12, height: 12))
        }
        NSColor(white: 1, alpha: 0.18 + progress * 0.77).setStroke()
        outline.lineWidth = 0.5 + progress * 0.6
        outline.stroke()
        if progress > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(progress)
            let badge = NSRect(x: bounds.maxX - 13, y: 3, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: badge.minX + 2.5, y: badge.minY + 5))
            check.line(to: NSPoint(x: badge.minX + 4.3, y: badge.minY + 3.2))
            check.line(to: NSPoint(x: badge.minX + 7.7, y: badge.minY + 6.7))
            NSColor.black.setStroke()
            check.lineWidth = 1.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func fittedRect(_ size: NSSize, inside rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if !store.selectedIDs.contains(capture.id) { store.select(capture.id) }
        return (superview as? MarqueeCanvas)?.makeSelectionMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
        wasSelected = store.selectedIDs.contains(capture.id)
        additiveClick = !event.modifierFlags.intersection([.option, .command]).isEmpty
        didDrag = false
        // Keep an existing group intact until mouse-up, so dragging one of its
        // selected members transfers the entire group.
        if !wasSelected { store.select(capture.id, extending: additiveClick) }
    }

    override func mouseUp(with event: NSEvent) {
        guard !didDrag else { return }
        if additiveClick {
            if wasSelected { store.select(capture.id, extending: true) }
        } else { store.select(capture.id) }
        if event.clickCount == 2 && !additiveClick { NSWorkspace.shared.open(capture.url) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return }
        let captures = store.dragCaptures(startingAt: capture.id)
        guard !captures.isEmpty else { return }
        didDrag = true
        store.beginDrag()
        let session = beginDraggingSession(with: Self.draggingItems(for: captures, origin: point),
            event: event, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    static func draggingItems(for captures: [Capture], origin: NSPoint) -> [NSDraggingItem] {
        captures.enumerated().map { index, capture in
            let item = NSDraggingItem(pasteboardWriter: capture.url as NSURL)
            let image = capture.thumbnail ?? NSWorkspace.shared.icon(forFile: capture.url.path)
            let offset = CGFloat(min(index, 3)) * 3
            let box = NSRect(x: origin.x - 36 + offset, y: origin.y - 22 - offset, width: 72, height: 44)
            item.setDraggingFrame(fittedRect(image.size, inside: box), contents: image)
            return item
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.finishDrag()
    }

    override func accessibilityPerformPress() -> Bool {
        store.select(capture.id, extending: NSEvent.modifierFlags.contains(.option))
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleCommandKey(event) { return }
        switch event.keyCode {
        case 123, 124:
            (superview as? CaptureStripView)?.focusNeighbor(of: capture,
                direction: event.keyCode == 123 ? -1 : 1, extending: event.modifierFlags.contains(.option))
        case 125, 126:
            (superview as? CaptureStripView)?.focusNeighbor(of: capture,
                direction: event.keyCode == 126 ? -1 : 1, vertical: true, extending: event.modifierFlags.contains(.option))
        case 49: store.select(capture.id, extending: event.modifierFlags.contains(.option))
        case 36: NSWorkspace.shared.open(capture.url)
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleCommandKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        // Hardware keys also work when the active input source is Russian.
        if event.keyCode == 0 { store.selectAll(); return true }
        if event.keyCode == 8 { store.copySelected(); return true }
        return false
    }
}
