import SwiftUI
import AppKit

struct ShelfGallery: NSViewRepresentable {
    let model: AppModel
    @ObservedObject var store: FileShelfStore
    let compact: Bool
    func makeNSView(context: Context) -> CaptureScrollView {
        let scroll = CaptureScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.documentView = ShelfCanvas(store: store)
        return scroll
    }
    func updateNSView(_ scroll: CaptureScrollView, context: Context) {
        guard let canvas = scroll.documentView as? ShelfCanvas else { return }
        canvas.makeSelectionMenu = { SelectionActionsMenu.files(model: model, store: store) }
        canvas.update(compact: compact)
    }
}

private struct ShelfGalleryCard: View {
    let file: ShelfFile
    @ObservedObject var store: FileShelfStore
    let compact: Bool
    let menu: () -> NSMenu?
    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: NativeArt.file(file.url)).resizable().scaledToFit()
                .frame(width: compact ? 47 : 60, height: compact ? 47 : 60).opacity(file.exists ? 1 : 0.4)
            Text(file.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }.padding(8).frame(width: compact ? 88 : 112, height: compact ? 94 : 120)
            .background(store.selected.contains(file.url) ? Color(white: 0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay { ShelfDragView(file: file, store: store, selectionMenu: menu).accessibilityLabel(file.name) }
            .help(file.exists ? file.url.path : "Файл перемещён. Добавь его снова.")
            .preferredColorScheme(.dark).foregroundStyle(.white)
    }
}

private final class ShelfCanvas: MarqueeCanvas {
    let store: FileShelfStore
    private var cards: [URL: NSHostingView<ShelfGalleryCard>] = [:]
    init(store: FileShelfStore) {
        self.store = store
        super.init(frame: .zero)
        currentSelection = { [weak store] in store?.selected ?? [] }
        setSelection = { [weak store] selection in
            guard let store else { return }
            let valid = selection.intersection(store.files.map(\.url))
            if store.selected != valid { store.selected = valid }
        }
        selectionActivity = { [weak store] in store?.isDragging = $0 }
        copySelection = { [weak store] in store?.copySelected() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(compact: Bool) {
        let urls = Set(store.files.map(\.url))
        for url in Set(cards.keys).subtracting(urls) { cards.removeValue(forKey: url)?.removeFromSuperview() }
        itemFrames = [:]
        let size = NSSize(width: compact ? 88 : 112, height: compact ? 94 : 120)
        for (index, file) in store.files.enumerated() {
            let content = ShelfGalleryCard(file: file, store: store, compact: compact, menu: { [weak self] in self?.makeSelectionMenu?() })
            let host: NSHostingView<ShelfGalleryCard>
            if let existing = cards[file.url] { host = existing; host.rootView = content }
            else {
                host = NSHostingView(rootView: content); host.sizingOptions = []
                cards[file.url] = host; addSubview(host)
            }
            host.frame = NSRect(x: 4 + CGFloat(index) * (size.width + 10), y: compact ? 3 : 4, width: size.width, height: size.height)
            itemFrames[file.url] = host.frame
        }
        contentExtent = NSSize(width: max(0, CGFloat(store.files.count) * (size.width + 10) - 2), height: compact ? 100 : 128)
        fitViewport(enclosingScrollView?.contentSize ?? .zero)
        if let clip = superview as? NSClipView {
            clip.scroll(to: NSPoint(x: min(clip.bounds.minX, max(0, bounds.width - clip.bounds.width)), y: 0))
        }
    }
}
