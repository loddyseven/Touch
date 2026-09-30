import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

enum HubTab: String, CaseIterable {
    case overview = "Обзор", files = "Файлы", clipboard = "Буфер", captures = "Снимки", scanner = "Текст со скрина", converter = "Форматы", music = "Музыка", apps = "Приложения"
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .files: return "folder"
        case .clipboard: return "doc.on.clipboard"
        case .captures: return "viewfinder"
        case .scanner: return "text.viewfinder"
        case .converter: return "film"
        case .music: return "music.note"
        case .apps: return "square.grid.2x2"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var expanded = false
    @Published var tab: HubTab = .overview
    @Published var showingSettings = false
    @Published var toast: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var notchHeight: CGFloat = 32
    @Published var notchWidth: CGFloat = 180
    let clipboard: ClipboardStore
    let captures: CaptureStore
    let recorder: ScreenRecorder
    let shelf: FileShelfStore
    let pinnedApps = PinnedApps()
    let music = MusicController()
    @Published var availableWidth: CGFloat = 960
    var english = false
    let audio = AudioController()
    let scanner = TextScanner()
    let converter = VideoConverter()
    let airDrop = AirDropSender()
    init(clipboard: ClipboardStore? = nil, captures: CaptureStore? = nil, shelf: FileShelfStore? = nil, recorder: ScreenRecorder? = nil) {
        self.shelf = shelf ?? FileShelfStore()
        self.clipboard = clipboard ?? ClipboardStore()
        self.captures = captures ?? CaptureStore()
        self.recorder = recorder ?? ScreenRecorder(folder: self.captures.folder)
        self.captures.systemCaptured = { [weak self] urls in self?.shelf.add(urls) }
        self.recorder.saved = { [weak self] url in
            guard let self else { return }
            self.captures.refresh(); self.captures.select(url)
            self.shelf.add([url]); self.tab = .captures
            self.notify("Видео сохранено"); self.showPanel?()
        }
    }
    var pendingTextCapture = false
    var beginSystemUI: (() -> Void)?
    var endSystemUI: (() -> Void)?
    var isPresentingSystemUI = false
    var isShowingCaptureMenu = false
    var panelContentHeight: CGFloat { 204 }
    var referencePanelHeight: CGFloat { panelContentHeight + 92 }
    var panelHeight: CGFloat { referencePanelHeight + notchHeight }
    var panelWidth: CGFloat { min(960, availableWidth) }
    var collapsedWidth: CGFloat { notchWidth + 2 + (recorder.phase.isBusy ? NotchGeometry.recordingWingWidth * 2 : music.hasTrack ? 64 : 0) }
    func tr(_ ru: String, _ en: String) -> String { english ? en : ru }
    func chooseShelfFiles() {
        beginSystemUI?(); defer { endSystemUI?() }
        let picker = NSOpenPanel()
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
        picker.prompt = "Добавить"
        if picker.runModal() == .OK { shelf.add(picker.urls) }
    }
    func chooseApps() {
        beginSystemUI?(); defer { endSystemUI?() }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = true; picker.directoryURL = URL(fileURLWithPath: "/Applications")
        if picker.runModal() == .OK { pinnedApps.add(picker.urls) }
    }
    func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        beginSystemUI?()
        airDrop.finished = { [weak self] message in self?.endSystemUI?(); if let message { self?.notify(message) } }
        if !airDrop.send(urls) { endSystemUI?(); notify("AirDrop сейчас недоступен") }
    }

    func captureText() {
        pendingTextCapture = true
        captures.capture()
        if !captures.isCapturing { pendingTextCapture = false }
    }

    func chooseImage() {
        beginSystemUI?()
        defer { endSystemUI?() }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.message = "Выбери изображение для распознавания текста"
        if picker.runModal() == .OK, let url = picker.url { scanner.recognize(url) }
    }

    func chooseFolder(destination: Bool) {
        beginSystemUI?()
        defer { endSystemUI?() }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = !destination
        picker.allowsMultipleSelection = !destination
        picker.canCreateDirectories = destination
        picker.treatsFilePackagesAsDirectories = false
        picker.prompt = "Выбрать"
        picker.message = destination ? "Куда сохранить готовые видео" : "Выбери видео или папку с видео"
        if !destination {
            picker.allowedContentTypes = VideoConverter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        if picker.runModal() == .OK {
            if destination { converter.destination = picker.url }
            else { converter.setSources(picker.urls) }
        }
    }

    func sendSelected() {
        let urls = captures.selectedCaptures.map(\.url)
        guard !urls.isEmpty else { return }
        beginSystemUI?()
        airDrop.finished = { [weak self] message in
            self?.endSystemUI?()
            if let message { self?.notify(message) }
        }
        if !airDrop.send(urls) {
            endSystemUI?()
            notify("AirDrop сейчас недоступен")
        }
    }
    var closePanel: (() -> Void)?
    var showPanel: (() -> Void)?
    var showSetup: (() -> Void)?
    private var toastTask: Task<Void, Never>?

    func notify(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func copy(_ clip: Clip) {
        notify(clipboard.copy(clip) ? "Скопировано — вставь через ⌘V" : "Не удалось скопировать")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                notify("Разреши запуск в настройках «Объекты входа»")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            notify("Не удалось изменить автозапуск. Перемести приложение в «Программы» и повтори.")
        }
    }
}

struct NotchGeometry {
    static let recordingWingWidth: CGFloat = 60

    let screen: NSRect
    let hasMeasuredNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var centerX: CGFloat
    var closedSize: NSSize { NSSize(width: notchWidth + 2, height: notchHeight + 1) }
    // Transparent margins preserve antialiasing around the expanded surface.
    var expandedWidth: CGFloat { min(960, screen.width - 36) }
    var openSize: NSSize { NSSize(width: expandedWidth + 24, height: notchHeight + 380) }
    var interactionFrame: NSRect {
        NSRect(x: centerX - expandedWidth / 2, y: screen.maxY - notchHeight - 348, width: expandedWidth, height: notchHeight + 348)
    }

    init(screen: NSRect, topInset: CGFloat, left: NSRect?, right: NSRect?) {
        self.screen = screen
        if let left, let right, topInset > 0, topInset < screen.height / 4,
           left.width > 0, right.width > 0, right.minX > left.maxX,
           left.minX >= screen.minX - 1, right.maxX <= screen.maxX + 1,
           right.minX - left.maxX < screen.width / 2 {
            hasMeasuredNotch = true
            notchHeight = topInset
            notchWidth = right.minX - left.maxX
            centerX = (right.minX + left.maxX) / 2
        } else {
            hasMeasuredNotch = false
            notchHeight = 24
            notchWidth = 180
            centerX = screen.midX
        }
    }

    func frame(expanded: Bool) -> NSRect {
        let size = expanded ? openSize : closedSize
        return NSRect(x: centerX - size.width / 2, y: screen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // The compact recording window ends at the visible notch; it must never
    // intercept clicks on the desktop below the stop button.
    var recordingFrame: NSRect {
        let width = closedSize.width + Self.recordingWingWidth * 2
        return NSRect(x: centerX - width / 2, y: screen.maxY - closedSize.height,
                      width: width, height: closedSize.height)
    }
    var recordingStopFrame: NSRect {
        NSRect(x: centerX + closedSize.width / 2, y: screen.maxY - notchHeight,
               width: Self.recordingWingWidth, height: notchHeight)
    }

    var hoverZone: NSRect { frame(expanded: false).insetBy(dx: -7, dy: -5) }
}
