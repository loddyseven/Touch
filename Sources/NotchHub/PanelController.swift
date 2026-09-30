import AppKit
import SwiftUI
import Carbon.HIToolbox

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.controller?.collapse(force: true)
    }
}

@MainActor
final class PanelController {
    let model: AppModel
    let panel: NotchPanel
    private var timer: Timer?
    private var geometry: NotchGeometry?
    private var leaveTime: Date?
    private var enterTime: Date?
    private var holdUntil = Date.distantPast
    private var compactRecordingAfter = Date.distantPast
    private var suspended = false
    private var keyboardOpen = false
    private var screenObserver: NSObjectProtocol?
    private var keyboardMonitor: Any?
    private weak var previousApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 1
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isRestorable = false
        panel.colorSpace = .deviceRGB
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.title = "Touch"
        panel.appearance = NSAppearance(named: .darkAqua)
        let hostingView = NSHostingView(rootView: HubView(model: model))
        // Panel dimensions belong to AppKit. SwiftUI's ideal-size constraints can
        // otherwise grow a borderless window when flexible empty states appear.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        updateScreen()
        panel.orderFrontRegardless()
        model.closePanel = { [weak self] in self?.collapse(force: true) }
        model.showPanel = { [weak self] in self?.expand(keyboard: true) }
        model.captures.beforeCapture = { [weak self] in
            guard let self else { return }
            self.suspended = true
            self.panel.orderOut(nil)
            self.previousApp?.activate(options: [])
        }
        model.recorder.beforeSelection = { [weak self] in
            guard let self else { return }
            self.suspended = true; self.model.isPresentingSystemUI = true
            self.panel.orderOut(nil)
        }
        model.recorder.afterSelection = { [weak self] selected in
            guard let self else { return }
            self.suspended = false; self.model.isPresentingSystemUI = false
            if selected { self.collapse(force: true); self.panel.orderFrontRegardless() }
            else { self.expand(keyboard: true) }
        }
        model.recorder.countdownBegan = { [weak self] in self?.collapse(force: true) }
        model.beginSystemUI = { [weak self] in
            guard let self else { return }
            self.suspended = true
            self.model.isPresentingSystemUI = true
            self.panel.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        model.endSystemUI = { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.model.isPresentingSystemUI = false
            self.expand(keyboard: true)
        }
        model.captures.captured = { [weak self] url in
            guard let self else { return }
            if let url { self.model.shelf.add([url]) }
            guard self.model.pendingTextCapture else { return }
            self.model.pendingTextCapture = false
            self.model.tab = .scanner
            if let url { self.model.scanner.recognize(url) }
        }
        model.captures.afterCapture = { [weak self] in
            guard let self else { return }
            self.suspended = false
            if self.model.tab != .scanner { self.model.tab = .captures }
            self.expand(keyboard: false)
            self.holdUntil = Date().addingTimeInterval(4)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateScreen() } }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53, self?.model.isPresentingSystemUI != true, event.window === self?.panel, self?.model.isShowingCaptureMenu != true, self?.model.captures.isDragging != true, self?.model.shelf.isDragging != true {
                Task { @MainActor in self?.collapse(force: true) }
                return nil
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
        timer?.tolerance = 0.025
    }

    private func updateScreen() {
        guard let screen = MacHardware.preferredScreen() else { geometry = nil; panel.orderOut(nil); return }
        geometry = NotchGeometry(screen: screen.frame, topInset: screen.safeAreaInsets.top,
            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        model.notchHeight = geometry!.notchHeight
        model.notchWidth = geometry!.notchWidth
        model.availableWidth = geometry!.expandedWidth
        panel.setFrame(geometry!.frame(expanded: true), display: true)
    }

    func suspendForSetup() {
        suspended = true
        model.expanded = false
        model.showingSettings = false
        panel.orderOut(nil)
    }

    func resumeAfterSetup() {
        suspended = false
        updateScreen()
        if geometry != nil { panel.orderFrontRegardless() }
    }

    func expand(keyboard: Bool = false) {
        guard !suspended, let geometry else { return }
        // Restore room for the expansion animation before revealing its content.
        panel.setFrame(geometry.frame(expanded: true), display: true)
        if !model.expanded {
            previousApp = NSWorkspace.shared.frontmostApplication
            model.captures.refresh()
        }
        model.expanded = true
        keyboardOpen = keyboard
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        holdUntil = Date().addingTimeInterval(keyboard ? 1 : TouchMotion.openingDuration)
        leaveTime = nil
        if keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
    }

    func collapse(force: Bool = false) {
        guard !suspended, !model.captures.isDragging, !model.shelf.isDragging, geometry != nil else { return }
        let wasExpanded = model.expanded
        model.expanded = false
        compactRecordingAfter = wasExpanded
            ? Date().addingTimeInterval(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : TouchMotion.closingDuration)
            : .distantPast
        keyboardOpen = false
        model.showingSettings = false
        panel.resignKey()
        panel.ignoresMouseEvents = true
        leaveTime = nil
        enterTime = nil
        // Require leaving the notch before a forced close can reopen it.
        if force { holdUntil = Date().addingTimeInterval(1) }
    }

    private func checkPointer() {
        guard !suspended, let geometry else { return }
        if model.isShowingCaptureMenu || model.captures.isDragging || model.shelf.isDragging || model.music.isScrubbing { leaveTime = nil; return }
        let point = NSEvent.mouseLocation
        let now = Date()
        if !model.expanded {
            let compactRecording = model.recorder.phase.isBusy && now >= compactRecordingAfter
            let frame = compactRecording ? geometry.recordingFrame : geometry.frame(expanded: true)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.ignoresMouseEvents = !compactRecording
            // Keep the stop button still under the cursor instead of expanding
            // the panel just as the user is about to press it.
            if model.recorder.phase.isBusy && geometry.recordingStopFrame.contains(point) {
                enterTime = nil
                return
            }
        }
        if model.expanded {
            let visibleFrame = NSRect(x: geometry.centerX - model.panelWidth / 2, y: geometry.screen.maxY - model.panelHeight,
                width: model.panelWidth, height: model.panelHeight)
            if visibleFrame.insetBy(dx: -3, dy: -3).contains(point) {
                keyboardOpen = false
                leaveTime = nil
            } else if now < holdUntil || keyboardOpen {
                leaveTime = nil
            } else if let leaveTime, now.timeIntervalSince(leaveTime) > 0.18 {
                collapse()
            } else if leaveTime == nil {
                leaveTime = now
            }
        } else if geometry.hoverZone.insetBy(dx: model.recorder.phase.isBusy ? -NotchGeometry.recordingWingWidth : model.music.hasTrack ? -32 : 0, dy: 0).contains(point), now >= holdUntil {
            if let enterTime, now.timeIntervalSince(enterTime) > 0.12 { expand() }
            else if enterTime == nil { enterTime = now }
        } else { enterTime = nil }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PanelController?
    private var statusItem: NSStatusItem?
    private let model = AppModel()
    private var hotKey: EventHotKeyRef?
    private var setupController: MacSetupWindowController?
    private var servicesStarted = false
    private var quittingAfterRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        registerHotKey()
        model.showSetup = { [weak self] in self?.showMacSetup() }
        model.recorder.becameIdle = { [weak self] in
            guard self?.quittingAfterRecording == true else { return }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        if MacSetup.needsSetup() || CommandLine.arguments.contains("--setup") { showMacSetup() }
        else { startTouch(expand: CommandLine.arguments.contains("--show")) }
    }

    func applicationWillTerminate(_ notification: Notification) { model.music.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.recorder.phase.isBusy else { return .terminateNow }
        if model.recorder.phase == .selecting { model.recorder.stop(); return .terminateNow }
        if case .countdown = model.recorder.phase { model.recorder.stop(); return .terminateNow }
        quittingAfterRecording = true
        model.recorder.stop()
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    private func startTouch(expand: Bool) {
        if controller == nil { controller = PanelController(model: model) }
        else { controller?.resumeAfterSetup() }
        if !servicesStarted { model.clipboard.start(); model.music.start(); servicesStarted = true }
        if expand { controller?.expand(keyboard: true) }
    }

    @objc private func showMacSetup() {
        if let setupController { setupController.present(); return }
        // Do not interrupt a screenshot, drag, or conversion to re-run setup.
        guard !model.recorder.phase.isBusy, !model.captures.isCapturing, !model.captures.isDragging, !model.converter.running, !model.isPresentingSystemUI else {
            model.notify("Заверши текущее действие перед настройкой Mac")
            return
        }
        controller?.suspendForSetup()
        let window = MacSetupWindowController(setup: MacSetup()) { [weak self] in
            self?.setupController = nil
            self?.startTouch(expand: true)
        }
        window.onDismiss = { [weak self] in
            self?.setupController = nil
            if MacSetup.needsSetup() { NSApp.terminate(nil) }
            else { self?.startTouch(expand: false) }
        }
        setupController = window
        window.present()
    }

    private func configureMenu() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Touch")
        status.button?.toolTip = "Touch — панель у чёлки"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Открыть Touch", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let setup = NSMenuItem(title: "Настроить под мой Mac…", action: #selector(showMacSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let shortcut = NSMenuItem(title: "Горячая клавиша: ⌃⌥Пробел", action: nil, keyEquivalent: "")
        menu.addItem(shortcut)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Пауза истории буфера", action: #selector(pauseClipboard), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let clear = NSMenuItem(title: "Очистить историю буфера", action: #selector(clearClipboard), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить Touch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu
        statusItem = status
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                if let setup = delegate.setupController { setup.present(); return }
                if delegate.model.expanded { delegate.controller?.collapse(force: true) }
                else { delegate.controller?.expand(keyboard: true) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E544348), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
            GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.notify("Горячая клавиша занята. Панель доступна при наведении и через меню.") }
    }

    @objc private func showPanel() {
        if setupController != nil || MacSetup.needsSetup() { showMacSetup() }
        else { controller?.expand(keyboard: true) }
    }
    @objc private func pauseClipboard(_ sender: NSMenuItem) {
        model.clipboard.isPaused.toggle()
        sender.state = model.clipboard.isPaused ? .on : .off
    }
    @objc private func clearClipboard() { model.clipboard.clear() }
    @objc private func quit() { NSApp.terminate(nil) }
}
