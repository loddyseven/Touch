import AppKit
import Combine
import UniformTypeIdentifiers

struct ShelfFile: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

@MainActor
final class FileShelfStore: ObservableObject {
    @Published private(set) var files: [ShelfFile] = []
    @Published var selected: Set<URL> = []
    @Published private(set) var canUndoClear = false
    private var lastRemoved: [ShelfFile] = []
    var isDragging = false
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        files = (defaults?.array(forKey: "Touch.fileShelf") as? [Data] ?? []).compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale) else { return nil }
            return ShelfFile(url: url)
        }
    }
    func add(_ urls: [URL]) {
        let existing = Set(files.map(\.url))
        var seen = existing
        let new = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0).inserted }
        files.insert(contentsOf: new.map { ShelfFile(url: $0) }, at: 0)
        if !new.isEmpty { selected = Set(new) }
        save()
    }
    func select(_ url: URL, extending: Bool) {
        if extending { if !selected.insert(url).inserted { selected.remove(url) } }
        else { selected = [url] }
    }
    var selectedURLs: [URL] { files.filter { selected.contains($0.url) && $0.exists }.map(\.url) }
    func removeSelected() {
        remove(files.filter { selected.contains($0.url) })
    }
    func clear() { remove(files) }
    private func remove(_ removed: [ShelfFile]) {
        guard !removed.isEmpty else { return }
        lastRemoved = removed
        let urls = Set(removed.map(\.url))
        files.removeAll { urls.contains($0.url) }
        selected.subtract(urls)
        canUndoClear = true
        save()
    }
    func undoClear() {
        let existing = Set(files.map(\.url))
        files.append(contentsOf: lastRemoved.filter { !existing.contains($0.url) })
        lastRemoved = []; canUndoClear = false
        save()
    }
    @discardableResult func copySelected(to board: NSPasteboard = .general) -> Bool {
        let urls = selectedURLs
        guard !urls.isEmpty else { return false }
        board.clearContents()
        return board.writeObjects(urls as [NSURL])
    }
    private func save() {
        defaults?.set(files.compactMap { try? $0.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }, forKey: "Touch.fileShelf")
    }
}

@MainActor
final class PinnedApps: ObservableObject {
    @Published private(set) var urls: [URL]
    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "Touch.pinnedApps")
        urls = (saved ?? ["/System/Library/CoreServices/Finder.app", "/System/Applications/Notes.app", "/Applications/Яндекс Музыка.app"]).map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension == "app" && !self.urls.contains(url) { self.urls.append(url) }
        save()
    }
    func remove(_ url: URL) { urls.removeAll { $0 == url }; save() }
    func open(_ url: URL) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    private func save() { UserDefaults.standard.set(urls.map(\.path), forKey: "Touch.pinnedApps") }
}

struct ShelfDragView: NSViewRepresentable {
    let file: ShelfFile
    @ObservedObject var store: FileShelfStore
    var selectionMenu: (() -> NSMenu?)?
    func makeNSView(context: Context) -> ShelfDragTarget { ShelfDragTarget() }
    func updateNSView(_ view: ShelfDragTarget, context: Context) { view.file = file; view.store = store; view.selectionMenu = selectionMenu }
}

import SwiftUI
final class ShelfDragTarget: NSView, NSDraggingSource {
    var file: ShelfFile?
    weak var store: FileShelfStore?
    var selectionMenu: (() -> NSMenu?)?
    private var down: NSEvent?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let file, let store else { return nil }
        if !store.selected.contains(file.url) { store.select(file.url, extending: false) }
        return selectionMenu?()
    }
    override func mouseDown(with event: NSEvent) {
        down = event
        guard let file, let store else { return }
        if !store.selected.contains(file.url) || !event.modifierFlags.intersection([.command, .option]).isEmpty {
            store.select(file.url, extending: !event.modifierFlags.intersection([.command, .option, .shift]).isEmpty)
        }
        if event.clickCount == 2, file.exists { NSWorkspace.shared.open(file.url) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let store, let file, hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 4 else { return }
        let urls = store.selected.contains(file.url) ? store.selectedURLs : [file.url]
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: CGFloat(index) * 5, y: CGFloat(index) * 5, width: 56, height: 56), contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        store.isDragging = true
        beginDraggingSession(with: items, event: event, source: self)
        self.down = nil
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { store?.isDragging = false }
}
