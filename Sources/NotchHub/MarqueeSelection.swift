import AppKit

struct MarqueeSelection {
    enum Mode { case replace, add, toggle }
    let origin: NSPoint
    let initial: Set<URL>
    let mode: Mode

    func rect(to point: NSPoint) -> NSRect {
        NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
            width: abs(origin.x - point.x), height: abs(origin.y - point.y))
    }
    func selected(to point: NSPoint, frames: [URL: NSRect]) -> Set<URL> {
        let rect = rect(to: point)
        let hits = Set(frames.filter { $0.value.intersects(rect) }.map(\.key))
        switch mode {
        case .replace: return hits
        case .add: return initial.union(hits)
        case .toggle: return initial.symmetricDifference(hits)
        }
    }
}

private final class SelectionOutline: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.11).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.65).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// Empty-space selection shared by both native shelves. Item views still own file dragging.
class MarqueeCanvas: NSView {
    var itemFrames: [URL: NSRect] = [:]
    var currentSelection: () -> Set<URL> = { [] }
    var setSelection: (Set<URL>) -> Void = { _ in }
    var selectionActivity: (Bool) -> Void = { _ in }
    var copySelection: () -> Void = {}
    var makeSelectionMenu: (() -> NSMenu?)?
    var contentExtent = NSSize.zero
    private var marquee: MarqueeSelection?
    private let outline = SelectionOutline()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        outline.isHidden = true
        outline.setAccessibilityElement(false)
        addSubview(outline)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func fitViewport(_ size: NSSize) {
        let newSize = NSSize(width: max(size.width, contentExtent.width), height: max(size.height, contentExtent.height))
        if frame.size != newSize { setFrameSize(newSize) }
    }
    func beginMarquee(at point: NSPoint, flags: NSEvent.ModifierFlags = []) {
        window?.makeFirstResponder(self)
        let mode: MarqueeSelection.Mode = !flags.intersection([.command, .option]).isEmpty ? .toggle : flags.contains(.shift) ? .add : .replace
        marquee = MarqueeSelection(origin: point, initial: currentSelection(), mode: mode)
        if mode == .replace { setSelection([]) }
        selectionActivity(true)
        addSubview(outline, positioned: .above, relativeTo: nil)
    }
    func moveMarquee(to point: NSPoint) {
        guard let marquee else { return }
        let rect = marquee.rect(to: point)
        guard rect.width > 3 || rect.height > 3 else {
            if !outline.isHidden {
                outline.isHidden = true
                setSelection(marquee.selected(to: point, frames: itemFrames))
            }
            return
        }
        outline.frame = rect
        outline.isHidden = false
        outline.needsDisplay = true
        setSelection(marquee.selected(to: point, frames: itemFrames))
    }
    func finishMarquee(cancelled: Bool = false) {
        if cancelled, let marquee { setSelection(marquee.initial) }
        marquee = nil
        outline.isHidden = true
        selectionActivity(false)
    }
    override func mouseDown(with event: NSEvent) { beginMarquee(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags) }
    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        moveMarquee(to: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { finishMarquee() }
    override func menu(for event: NSEvent) -> NSMenu? { currentSelection().isEmpty ? nil : makeSelectionMenu?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, marquee != nil { finishMarquee(cancelled: true); return }
        if event.modifierFlags.contains(.command), event.keyCode == 0 { setSelection(Set(itemFrames.keys)); return }
        if event.modifierFlags.contains(.command), event.keyCode == 8 { copySelection(); return }
        super.keyDown(with: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, marquee != nil { finishMarquee(cancelled: true) }
        super.viewWillMove(toWindow: newWindow)
    }
}

@MainActor final class SelectionActionsMenu: NSMenu {
    private var actions: [() -> Void] = []
    init() { super.init(title: "") }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func add(_ title: String, symbol: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self; item.tag = actions.count
        actions.append(action); addItem(item)
    }
    @objc private func invoke(_ sender: NSMenuItem) { actions[sender.tag]() }

    static func captures(model: AppModel, store: CaptureStore) -> NSMenu {
        let menu = SelectionActionsMenu()
        menu.add(model.tr("Скопировать", "Copy"), symbol: "doc.on.doc") { store.copySelected() }
        menu.add("AirDrop", symbol: "airplayaudio") { model.sendSelected() }
        menu.add(model.tr("Открыть", "Open"), symbol: "arrow.up.right.square") { store.selectedCaptures.forEach { NSWorkspace.shared.open($0.url) } }
        menu.add(model.tr("Показать в Finder", "Show in Finder"), symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(store.selectedCaptures.map(\.url)) }
        if store.selectedCaptures.count == 1, let item = store.selectedCaptures.first, !item.isVideo {
            menu.add(model.tr("Распознать текст", "Recognize text"), symbol: "text.viewfinder") { model.tab = .scanner; model.scanner.recognize(item.url) }
        }
        menu.addItem(.separator())
        menu.add(model.tr("Убрать из Touch", "Remove from Touch"), symbol: "trash") { store.removeSelected() }
        return menu
    }
    static func files(model: AppModel, store: FileShelfStore) -> NSMenu {
        let menu = SelectionActionsMenu()
        menu.add(model.tr("Скопировать файлы", "Copy files"), symbol: "doc.on.doc") { model.notify(store.copySelected() ? model.tr("Файлы скопированы", "Files copied") : model.tr("Файлы недоступны", "Files unavailable")) }
        menu.add("AirDrop", symbol: "airplayaudio") { model.sendFiles(store.selectedURLs) }
        menu.add(model.tr("Открыть", "Open"), symbol: "arrow.up.right.square") { store.selectedURLs.forEach { NSWorkspace.shared.open($0) } }
        menu.add(model.tr("Показать в Finder", "Show in Finder"), symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(store.selectedURLs) }
        menu.addItem(.separator())
        menu.add(model.tr("Убрать из Touch", "Remove from Touch"), symbol: "trash") { store.removeSelected() }
        return menu
    }
}
