import AppKit
import Combine
import CoreGraphics
import AVFoundation

struct Capture: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let date: Date
    let modifiedAt: Date
    let byteCount: Int
    var isVideo: Bool { ["mp4", "mov"].contains(url.pathExtension.lowercased()) }
    @MainActor var thumbnail: NSImage? { CaptureThumbnails.image(url: url, modifiedAt: modifiedAt) }

    static let fileKeys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    static let extensions = Set(["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "pdf", "mp4", "mov"])

    static func read(_ url: URL, systemOnly: Bool = false, previouslyValidated: Capture? = nil) -> Capture? {
        guard extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: Set(fileKeys)),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let capture = Capture(url: url.standardizedFileURL, date: values.creationDate ?? .distantPast,
            modifiedAt: values.contentModificationDate ?? .distantPast, byteCount: values.fileSize ?? 0)
        if systemOnly {
            guard !capture.isVideo else { return nil }
            guard SystemCaptureMonitor.isSystemScreenshot(url), (values.fileSize ?? 0) > 0 else { return nil }
            if capture == previouslyValidated { return capture }
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return nil }
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(source) > 0,
                      CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 16,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) != nil,
                      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
            }
        }
        return capture
    }

    static func newestFirst(_ lhs: Capture, _ rhs: Capture) -> Bool {
        lhs.date == rhs.date ? lhs.url.path > rhs.url.path : lhs.date > rhs.date
    }
}

extension Notification.Name {
    static let captureThumbnailReady = Notification.Name("TouchCaptureThumbnailReady")
}

@MainActor private enum CaptureThumbnails {
    static var pending = Set<String>()
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        return cache
    }()

    static func image(url: URL, modifiedAt: Date) -> NSImage? {
        let key = "\(url.path):\(modifiedAt.timeIntervalSince1970)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
            guard pending.insert(key as String).inserted else { return nil }
            Task {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 420, height: 420)
                if let result = try? await generator.image(at: .zero) {
                    cache.setObject(NSImage(cgImage: result.image, size: .zero), forKey: key)
                } else { cache.setObject(NSWorkspace.shared.icon(forFile: url.path), forKey: key) }
                pending.remove(key as String)
                NotificationCenter.default.post(name: .captureThumbnailReady, object: url)
            }
            return nil
        }
        if url.pathExtension.lowercased() == "pdf", let image = NSImage(contentsOf: url) {
            cache.setObject(image, forKey: key)
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 420,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}

@MainActor
final class CaptureStore: ObservableObject {
    private struct HiddenCapture: Codable, Equatable {
        let created: Date
        let modified: Date
        let bytes: Int
        init(_ capture: Capture) {
            created = capture.date; modified = capture.modifiedAt; bytes = capture.byteCount
        }
    }
    @Published private(set) var items: [Capture] = []
    @Published private(set) var isCapturing = false
    @Published var message: String?
    @Published private(set) var needsPermissionHelp = false
    @Published private(set) var needsFolderPermissionHelp = false
    @Published private(set) var selectedIDs: Set<URL> = []
    @Published private(set) var canUndoClear = false
    private(set) var isDragging = false
    private var process: Process?
    var beforeCapture: (() -> Void)?
    var afterCapture: (() -> Void)?
    var captured: ((URL?) -> Void)?
    var systemCaptured: (([URL]) -> Void)?
    private var systemCaptures: [Capture] = []
    private var systemMonitor: SystemCaptureMonitor?
    private let defaults: UserDefaults?
    private var hiddenCaptures: [String: HiddenCapture] = [:]
    private var lastRemoved: [String] = []
    private static let hiddenKey = "Touch.hiddenCaptures.v1"
    let folder: URL

    init(folder: URL? = nil, systemCaptureDirectories: (@Sendable () -> [URL])? = nil, defaults: UserDefaults? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchHub", isDirectory: true)
        self.defaults = defaults ?? (folder == nil ? .standard : nil)
        if let data = self.defaults?.data(forKey: Self.hiddenKey),
           let saved = try? JSONDecoder().decode([String: HiddenCapture].self, from: data) {
            hiddenCaptures = saved
        }
        refresh()
        // Explicit fixture folders never inspect the user's desktop.
        if folder == nil || systemCaptureDirectories != nil {
            let directories: @Sendable () -> [URL] = systemCaptureDirectories ?? { SystemCaptureMonitor.screenshotDirectories() }
            systemMonitor = SystemCaptureMonitor(directories: directories) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self else { return }
                    self.systemCaptures = snapshot.captures
                    self.needsFolderPermissionHelp = snapshot.accessDenied
                    self.publishCaptures()
                    let visible = Set(self.items.map(\.url))
                    let added = snapshot.added.filter { visible.contains($0) }
                    if !added.isEmpty { self.systemCaptured?(added) }
                }
            }
        }
    }

    deinit { systemMonitor?.stop() }

    func refresh() {
        publishCaptures()
        systemMonitor?.rescan()
    }

    private func publishCaptures() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: Capture.fileKeys, options: [.skipsHiddenFiles])) ?? []
        let own = urls.compactMap { Capture.read($0) }
        var byURL = Dictionary(own.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for capture in systemCaptures where FileManager.default.fileExists(atPath: capture.url.path) {
            byURL[capture.id] = capture
        }
        let updated = byURL.values.filter { hiddenCaptures[$0.url.path] != HiddenCapture($0) }
            .sorted(by: Capture.newestFirst)
        if items != updated { items = updated }
        selectedIDs.formIntersection(items.map(\.id))
    }

    var selectedCaptures: [Capture] { items.filter { selectedIDs.contains($0.id) } }

    func select(_ id: URL, extending: Bool = false) {
        guard items.contains(where: { $0.id == id }) else { return }
        if extending {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
        } else { selectedIDs = [id] }
        message = nil
    }

    func setSelection(_ ids: Set<URL>) {
        let valid = ids.intersection(items.map(\.id))
        if selectedIDs != valid { selectedIDs = valid; message = nil }
    }
    func clearSelection() { selectedIDs = []; message = nil }
    func selectAll() { selectedIDs = Set(items.map(\.id)); message = nil }

    // Clearing the gallery only dismisses entries. Originals stay in their
    // existing folders, and their fingerprints prevent a rescan from restoring them.
    func clear() { remove(items) }
    func removeSelected() { remove(selectedCaptures) }
    private func remove(_ captures: [Capture]) {
        guard !captures.isEmpty else { return }
        lastRemoved = captures.map { $0.url.path }
        for capture in captures { hiddenCaptures[capture.url.path] = HiddenCapture(capture) }
        saveHiddenCaptures()
        canUndoClear = true; message = nil
        publishCaptures()
    }
    func undoClear() {
        for path in lastRemoved { hiddenCaptures.removeValue(forKey: path) }
        lastRemoved = []; canUndoClear = false; message = nil
        saveHiddenCaptures()
        publishCaptures()
    }
    private func saveHiddenCaptures() {
        if let data = try? JSONEncoder().encode(hiddenCaptures) { defaults?.set(data, forKey: Self.hiddenKey) }
    }

    func dragCaptures(startingAt id: URL) -> [Capture] {
        guard items.contains(where: { $0.id == id }) else { return [] }
        if !selectedIDs.contains(id) { select(id) }
        let result = selectedCaptures
        guard result.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else {
            refresh()
            message = "Один из файлов недоступен"
            return []
        }
        return result
    }

    func beginDrag() { isDragging = true }
    func finishDrag() { isDragging = false }

    @discardableResult
    func copySelected(to board: NSPasteboard = .general) -> Bool {
        let selected = selectedCaptures
        guard !selected.isEmpty else { return false }
        guard selected.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else {
            message = "Один из файлов недоступен"
            refresh()
            return false
        }
        needsPermissionHelp = false
        board.clearContents()
        // File URLs remain separate pasteboard items, so Finder and upload
        // targets receive every selected PNG at its original quality.
        let success = board.writeObjects(selected.map { $0.url as NSURL })
        message = success ? "Скопировано: \(selected.count)" : "Не удалось скопировать"
        return success
    }

    func capture(window: Bool = false) {
        guard !isCapturing else { return }
        needsPermissionHelp = false
        // Request from the app itself so macOS records this bundle's stable
        // signature, instead of trying to prompt from the capture subprocess.
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            needsPermissionHelp = true
            message = "Разреши Touch запись экрана и перезапусти приложение."
            return
        }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { message = "Не удалось создать папку снимков в «Изображениях»."; return }
        isCapturing = true
        message = nil
        beforeCapture?()
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("Снимок \(date.string(from: Date())) \(UUID().uuidString.prefix(4)).png")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", window ? "-w" : "-s", url.path]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Task { @MainActor in
                    guard let self else { return }
                    self.isCapturing = false
                    self.process = nil
                    self.refresh()
                    if FileManager.default.fileExists(atPath: url.path) {
                        self.select(url)
                        self.message = "Сохранено"
                    } else {
                        if !errorText.isEmpty && status != 0 {
                            self.needsPermissionHelp = true
                            self.message = "Нет доступа к экрану. Перезапусти Touch после разрешения."
                        } else {
                            self.message = "Снимок отменён"
                        }
                    }
                    self.captured?(FileManager.default.fileExists(atPath: url.path) ? url : nil)
                    self.afterCapture?()
                }
            }
            self.process = process
            do { try process.run() }
            catch {
                self.process = nil
                isCapturing = false
                message = "Не удалось запустить инструмент снимков."
                captured?(nil)
                afterCapture?()
            }
        }
    }

    @discardableResult
    func copy(_ capture: Capture) -> Bool {
        needsPermissionHelp = false
        guard let image = NSImage(contentsOf: capture.url) else { message = "Файл снимка недоступен."; return false }
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.writeObjects([image])
        message = success ? "Скопировано" : "Не удалось скопировать"
        return success
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { message = "Не удалось открыть папку снимков." }
    }

    func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openFolderPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
}
