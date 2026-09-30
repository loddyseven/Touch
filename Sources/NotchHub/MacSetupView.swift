import AppKit
import SwiftUI

struct MacSetupView: View {
    @ObservedObject var setup: MacSetup
    var body: some View {
        MacSetupSurface(stage: setup.stage, selected: setup.selected, snapshot: setup.snapshot,
            verification: setup.verification, select: { setup.selected = $0 },
            verify: { setup.verify() }, back: { setup.chooseAgain() },
            useDetected: { setup.useDetected() }, complete: { setup.complete() })
    }
}

// The app and the first-launch film use this same view; review renders are fixtures.
struct MacSetupSurface: View {
    let stage: MacSetup.Stage
    let selected: MacFamily
    let snapshot: MacSnapshot
    let verification: MacVerification
    var english = false
    var select: (MacFamily) -> Void = { _ in }
    var verify: () -> Void = {}
    var back: () -> Void = {}
    var useDetected: () -> Void = {}
    var complete: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func text(_ ru: String, _ en: String) -> String { english ? en : ru }
    private var hasNotch: Bool { snapshot.display?.hasNotch == true }
    private var ready: Bool { stage == .result && verification.canContinue }
    private var title: String {
        if stage == .choose { return text("Ваш Mac.\nВаш Touch.", "Your Mac.\nYour Touch.") }
        if stage == .checking { return text("Знакомимся\nс вашим Mac.", "Getting to know\nyour Mac.") }
        if verification == .mismatch { return text("Модель\nне совпадает.", "A different\nMac detected.") }
        if verification == .noDisplay { return text("Подключите\nэкран.", "Connect\na display.") }
        if verification == .unrecognized { return text("Настроим\nпо экрану.", "Made for\nyour display.") }
        if !hasNotch, snapshot.display?.topInset ?? 0 > 0 { return text("Настроим\nпо экрану.", "Made for\nyour display.") }
        return hasNotch ? text("Идеальное\nсовпадение.", "A perfect\nfit.") : text("У этого экрана\nнет чёлки.", "No notch.\nStill Touch.")
    }
    private var detail: String {
        if stage == .choose { return text("Выберите модель. Размеры экрана\nпроверим автоматически.", "Choose your model. We’ll check\nthe display automatically.") }
        if stage == .checking { return text("Проверяем модель Mac и доступную область экрана.", "Checking your Mac and its available screen area.") }
        if verification == .mismatch { return text("Выбрано: \(selected.title).\nСистема определила: \(snapshot.family?.title ?? "Mac").", "Selected: \(selected.title).\nDetected: \(snapshot.family?.title ?? "Mac").") }
        if verification == .noDisplay { return text("Не удалось получить параметры экрана.\nПодключите дисплей и повторите проверку.", "Display information is unavailable.\nConnect a screen and try again.") }
        if verification == .unrecognized { return text("Модель не распознана. Используем реальные\nпараметры подключённого экрана.", "Model unrecognized. We’ll use the actual\nmeasurements of your connected display.") }
        if hasNotch { return text("Touch подстроен под чёлку вашего экрана.\nНичего не нужно двигать вручную.", "Touch fits your display’s notch.\nNo manual adjustments.") }
        if snapshot.display?.topInset ?? 0 > 0 { return text("Размеры выреза недоступны.\nИспользуем компактную панель сверху.", "Notch measurements are unavailable.\nWe’ll use a compact panel at the top.") }
        return text("Подгонка под чёлку недоступна.\nTouch будет компактной панелью сверху.", "Notch fitting isn’t available on this display.\nTouch stays as a compact panel at the top.")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Touch").font(.system(size: 19, weight: .semibold)).tracking(-0.65)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Capsule().fill(.white.opacity(index == (stage == .choose ? 0 : stage == .checking ? 1 : 2) ? 0.85 : 0.16)).frame(width: index == (stage == .choose ? 0 : stage == .checking ? 1 : 2) ? 21 : 5, height: 5)
                    }
                }.accessibilityLabel(text("Первый запуск", "First launch"))
            }.padding(.top, 31).padding(.horizontal, 38)
            ScreenFitPreview(hasNotch: hasNotch, expanded: ready, checking: stage == .checking)
                .frame(width: 420, height: 146).padding(.top, 26).accessibilityHidden(true)
            VStack(spacing: 15) {
                Text(title).font(.system(size: 35, weight: .semibold)).tracking(-1.35).lineSpacing(-1).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineSpacing(4).multilineTextAlignment(.center).frame(height: 45, alignment: .top)
            }.frame(height: 153, alignment: .top).padding(.horizontal, 24)
                .id(title).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 7)))
            Group {
                if stage == .choose { choices }
                else if stage == .checking { checking }
                else { result }
            }.frame(width: 444, height: 157, alignment: .top)
                .id(stage).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
            Spacer(minLength: 0)
            action.frame(width: 444, height: 44)
            Text(stage == .choose ? text("Обнаружено: ", "Detected: ") + (snapshot.family?.title ?? text("модель не распознана", "unknown model")) : text("Настройку можно повторить в меню Touch", "You can run setup again from the Touch menu"))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.top, 14).padding(.bottom, 28)
        }
        .frame(width: 600, height: 680)
        .background {
            ZStack {
                Color(white: 0.028)
                RadialGradient(colors: [Color(white: 0.14), .clear], center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0, endRadius: 390)
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark).tint(.white)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: stage)
        .buttonStyle(SetupPressStyle())
    }
    private var choices: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            ForEach(MacFamily.allCases) { family in
                Button { select(family) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: family == .other ? "desktopcomputer" : "laptopcomputer").font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.68))
                        Text(family == .other ? text("Другой Mac", "Other Mac") : family.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        if selected == family { Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)) }
                    }.padding(.horizontal, 13).frame(height: 43)
                        .background(.white.opacity(selected == family ? 0.11 : 0.025), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(selected == family ? 0.40 : 0.10), lineWidth: 0.7) }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.accessibilityAddTraits(selected == family ? .isSelected : [])
            }
        }
    }
    private var checking: some View {
        VStack(spacing: 0) {
            statusRow(text("Модель Mac", "Mac model"), text("Проверяем", "Checking"), symbol: "laptopcomputer", verified: false)
            statusRow(text("Геометрия экрана", "Screen geometry"), text("Определяем", "Measuring"), symbol: "rectangle.topthird.inset.filled", verified: false)
        }
    }
    private var result: some View {
        VStack(spacing: 0) {
            statusRow(snapshot.family?.title ?? text("Модель Mac", "Mac model"), verification == .confirmed ? text("Подтверждено", "Verified") : verification == .mismatch ? text("Другая модель", "Different model") : text("Не подтверждено", "Unverified"), symbol: "laptopcomputer", verified: verification == .confirmed)
            statusRow(text("Панель Touch", "Touch panel"), hasNotch ? text("По размеру чёлки", "Fits your notch") : text("Компактный режим", "Compact mode"), symbol: "rectangle.topthird.inset.filled", verified: ready)
            if stage == .result { Button(text("Изменить модель", "Change model"), action: back).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(height: 37).padding(.top, 9) }
        }
    }
    private func statusRow(_ label: String, _ value: String, symbol: String, verified: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.5)).frame(width: 20)
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.83))
            Spacer()
            Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(verified ? 0.72 : 0.43))
            if verified { Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color(red: 0.60, green: 0.78, blue: 0.66)) }
        }.frame(height: 48).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
    }
    private var action: some View {
        Button {
            if stage == .choose { verify() }
            else if verification == .mismatch { useDetected() }
            else if verification == .noDisplay { verify() }
            else { complete() }
        } label: {
            Text(stage == .choose ? text("Проверить Mac", "Check my Mac") : stage == .checking ? text("Проверяем…", "Checking…") : verification == .mismatch ? text("Использовать обнаруженную модель", "Use detected model") : verification == .noDisplay ? text("Проверить ещё раз", "Try again") : text("Начать с Touch", "Start using Touch"))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.black.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(stage == .checking ? 0.24 : 0.94), in: RoundedRectangle(cornerRadius: 11))
        }.disabled(stage == .checking).keyboardShortcut(.defaultAction)
    }
}

struct ScreenFitPreview: View {
    let hasNotch: Bool
    let expanded: Bool
    let checking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.065)], startPoint: .top, endPoint: .bottom))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.18), lineWidth: 0.6) }
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    NotchShape(radius: expanded ? 14 : 7).fill(.black)
                    VStack(spacing: 16) {
                        Circle().fill(.white.opacity(hasNotch ? 0.13 : 0)).frame(width: 3, height: 3).padding(.top, 8)
                        if expanded {
                            HStack(spacing: 20) {
                                Image(systemName: "text.viewfinder")
                                Image(systemName: "camera")
                            }.font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.85))
                            Capsule().fill(.white.opacity(0.25)).frame(width: 116, height: 3)
                        }
                    }
                }.frame(width: expanded ? 204 : hasNotch ? 128 : 96, height: expanded ? 88 : hasNotch ? 22 : 17)
                Spacer()
            }
            if checking {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    let phase = reduceMotion ? 0.5 : (sin(timeline.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
                    Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 1).offset(x: -105 + 210 * phase, y: 41)
                }
            }
        }.frame(height: 125).mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .animation(reduceMotion ? nil : .smooth(duration: TouchMotion.openingDuration), value: expanded)
    }
}

private struct SetupPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor
final class MacSetupWindowController: NSWindowController, NSWindowDelegate {
    let setup: MacSetup
    var onDismiss: (() -> Void)?
    private var completing = false
    init(setup: MacSetup, onComplete: @escaping () -> Void) {
        self.setup = setup
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Touch — первый запуск"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.03, alpha: 1)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: MacSetupView(setup: setup))
        window.delegate = self
        window.center()
        setup.onComplete = { [weak self] in
            guard let self else { return }
            self.completing = true
            self.close()
            onComplete()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() { NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { setup.cancel(); if !completing { onDismiss?() } }
}
