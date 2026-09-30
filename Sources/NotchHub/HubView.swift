import SwiftUI
import AppKit

struct NotchShape: Shape {
    var radius: CGFloat = 22
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous).path(in: rect)
    }
}

private extension View {
    func placed(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, alignment: Alignment = .leading) -> some View {
        frame(width: width, height: height, alignment: alignment).offset(x: x, y: y)
    }
}

private enum TouchImages {
    static let folder = NSWorkspace.shared.icon(for: .folder)
    static let assets: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ["preview", "screenshot", "textedit", "video", "airdrop-reference"] {
            let sourceResource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name).png")
            let url = Bundle.main.url(forResource: name, withExtension: "png") ?? sourceResource
            if let image = NSImage(contentsOf: url) {
                if name == "airdrop-reference" {
                    result[name] = NSImage(size: NSSize(width: 139, height: 139), flipped: false) { rect in
                        NSBezierPath(roundedRect: rect, xRadius: 41.7, yRadius: 41.7).addClip()
                        image.draw(in: rect, from: NSRect(x: image.size.width * 13 / 168, y: image.size.height * 5 / 168,
                            width: image.size.width * 139 / 168, height: image.size.height * 139 / 168), operation: .sourceOver, fraction: 1)
                        return true
                    }
                } else if name == "preview" {
                    result[name] = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
                        image.draw(in: rect, from: NSRect(x: 12, y: 8, width: image.size.width - 24, height: image.size.height - 16), operation: .sourceOver, fraction: 1)
                        return true
                    }
                } else { result[name] = image }
            }
        }
        return result
    }()
}

private struct MacIcon: View {
    let name: String
    var size: CGFloat = 26
    var body: some View {
        Image(nsImage: name == "folder" ? TouchImages.folder : TouchImages.assets[name] ?? NSImage())
            .resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
            .rotationEffect(.degrees(name == "screenshot" ? 10 : 0)).accessibilityHidden(true)
    }
}

struct LegacyHubView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion = NotchMotion()
    private var pageID: String { model.showingSettings ? "settings" : model.tab.rawValue }
    private var shownWidth: CGFloat { model.notchWidth + 2 + (model.panelWidth - model.notchWidth - 2) * motion.geometry }
    private var shownHeight: CGFloat { model.notchHeight + 1 + (model.panelHeight - model.notchHeight - 1) * motion.geometry }
    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if model.showingSettings { SettingsPage(model: model) }
                else {
                    switch model.tab {
                    case .overview, .captures: HomePage(model: model, captures: model.captures, clipboard: model.clipboard, audio: model.audio)
                    case .clipboard: ClipboardPage(model: model, store: model.clipboard)
                    case .scanner: ScannerPage(model: model, scanner: model.scanner)
                    case .converter: ConverterPage(model: model, converter: model.converter)
                    case .files, .music, .apps: EmptyView()
                    }
                }
            }
            .id(pageID)
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
            .frame(width: 280, height: model.referencePanelHeight, alignment: .topLeading)
            .offset(y: model.notchHeight - 34)
            .opacity(motion.opacity)
            .scaleEffect(motion.closing && !reduceMotion ? shownWidth / model.panelWidth : 1, anchor: UnitPoint(x: 0.5, y: 14 / model.panelHeight))
        }
        .frame(width: shownWidth, height: shownHeight, alignment: .top)
        .background(Color(white: 0.006))
        .clipShape(NotchShape(radius: 12 + 10 * motion.geometry))
        .overlay { NotchShape(radius: 12 + 10 * motion.geometry).stroke(.white.opacity(0.1 - motion.geometry * 0.025), lineWidth: 0.6).allowsHitTesting(false) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: pageID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(model.expanded).accessibilityHidden(!model.expanded)
        .preferredColorScheme(.dark).tint(.white).foregroundStyle(.white).font(.system(size: 11))
        .buttonStyle(QuietPressStyle())
        .onAppear { motion.set(expanded: model.expanded, reduceMotion: reduceMotion) }
        .onChange(of: model.expanded) { _, expanded in motion.set(expanded: expanded, reduceMotion: reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in motion.set(expanded: model.expanded, reduceMotion: reduced) }
    }
}

private struct QuietPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.68 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MiniIcon: View {
    let symbol: String
    let label: String
    var size: CGFloat = 11
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white.opacity(hovered ? 0.96 : 0.62))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.onHover { hovered = $0 }.help(label).accessibilityLabel(label)
    }
}

private struct PageHeader: View {
    let title: String
    let model: AppModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            MiniIcon(symbol: "chevron.left", label: "Назад", size: 10) { model.tab = .overview; model.showingSettings = false }.offset(x: 7, y: 32)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).placed(32, 36, 185, 20)
        }.frame(width: 280, height: 64, alignment: .topLeading)
    }
}

struct HomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var captures: CaptureStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var audio: AudioController
    @State private var copied = false
    private var status: String {
        if captures.needsPermissionHelp { return captures.message ?? "Нужен доступ к экрану" }
        if let toast = model.toast, !toast.hasPrefix("Скопировано") { return toast }
        return captures.selectedIDs.isEmpty ? "⌥ + клик — выбрать снимки" : "Выбрано: \(captures.selectedIDs.count)"
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Снимки").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.94)).placed(14, 38, 87, 20)
            MiniIcon(symbol: "ellipsis", label: "Настройки Touch", size: 10) { model.showingSettings = true }.offset(x: 119, y: 37)
            Button { model.tab = .scanner } label: { MacIcon(name: "preview").frame(width: 32, height: 32) }
                .accessibilityLabel("Текст со скрина").help("Текст со скрина").offset(x: 190, y: 35)
            Button { captures.capture() } label: { MacIcon(name: "screenshot").frame(width: 32, height: 32) }
                .accessibilityLabel("Снимок области").help("Снимок области").disabled(captures.isCapturing).offset(x: 227, y: 35)
            if captures.items.isEmpty {
                Button { captures.capture() } label: {
                    Label("Сделать снимок", systemImage: "plus").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        .frame(width: 252, height: 42).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                }.disabled(captures.isCapturing).offset(x: 14, y: 78)
            } else { CaptureGallery(store: captures).placed(14, 78, 252, 42) }
            Button { model.tab = .clipboard } label: {
                FeatureRow(icon: "textedit", title: "Буфер обмена", detail: clipboard.items.first?.title ?? "Текст и изображения", trailing: "\(clipboard.items.count)", titleSize: 9)
            }.offset(x: 14, y: 133)
            Button { model.tab = .converter } label: {
                FeatureRow(icon: "video", title: "Конвертация видео", detail: "Выбрать папку", trailing: model.converter.format, titleSize: 10)
            }.offset(x: 14, y: 173)
            MiniIcon(symbol: audio.muted ? "speaker.slash" : "speaker.wave.2", label: audio.muted ? "Включить звук" : "Выключить звук", size: 12) { audio.toggleMute() }.offset(x: 10, y: 210)
            Slider(value: Binding(get: { audio.volume }, set: { audio.setVolume($0) }), in: 0...1)
                .controlSize(.mini).disabled(!audio.available).accessibilityLabel("Громкость").placed(37, 213, 202, 18)
            Text(audio.available ? "\(Int(audio.volume * 100))" : "—").monospacedDigit().font(.system(size: 8)).foregroundStyle(.white.opacity(0.56)).placed(246, 216, 20, 12, alignment: .trailing)
            Text(status).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).placed(14, 236, 193, 14)
                .help(status).contextMenu { Button("Снять выделение") { captures.clearSelection() } }
            if captures.needsPermissionHelp {
                MiniIcon(symbol: "exclamationmark.circle", label: "Разрешить запись экрана") { captures.openPermissions() }.offset(x: 212, y: 229)
            } else if !captures.selectedIDs.isEmpty {
                Button { model.sendSelected() } label: { MacIcon(name: "airdrop-reference", size: 18).frame(width: 26, height: 26) }
                    .help("AirDrop выбранных снимков").accessibilityLabel("AirDrop: отправить выбранные снимки").offset(x: 214, y: 228)
                MiniIcon(symbol: copied ? "checkmark" : "doc.on.doc", label: "Копировать выбранные снимки", size: 13) {
                    copied = captures.copySelected()
                    Task { try? await Task.sleep(for: .seconds(1)); copied = false }
                }.offset(x: 244, y: 228)
            }
        }.frame(width: 280, height: 258, alignment: .topLeading)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    let trailing: String
    var titleSize: CGFloat
    @State private var hovered = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            MacIcon(name: icon).offset(y: 2)
            Text(title).font(.system(size: titleSize)).foregroundStyle(.white.opacity(icon == "textedit" ? 0.66 : 0.74)).placed(36, 1, 174, 13)
            Text(detail).font(.system(size: icon == "textedit" ? 10 : 9)).foregroundStyle(.white.opacity(icon == "textedit" ? 0.88 : 0.52)).lineLimit(1).placed(36, 14, 167, 14)
            Text(trailing).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).placed(209, 10, 27, 15, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).placed(243, 10, 9, 15)
        }.frame(width: 252, height: 32, alignment: .topLeading).contentShape(Rectangle())
            .background(.white.opacity(hovered ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 7)).onHover { hovered = $0 }
    }
}

private struct ClipboardPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ClipboardStore
    @State private var selected: UUID?
    @State private var copied: UUID?
    var body: some View {
        ZStack(alignment: .topLeading) {
            PageHeader(title: "Буфер обмена", model: model)
            Menu {
                Button(store.isPaused ? "Продолжить историю" : "Пауза истории") { store.isPaused.toggle() }
                Button("Очистить историю") { store.clear() }
            } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).placed(243, 32, 24, 24).accessibilityLabel("Управление историей")
            if store.accessDenied || store.needsConsent {
                Button("Разрешить доступ к буферу") {
                    if store.accessDenied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") { NSWorkspace.shared.open(url) }
                    else { store.poll(userInitiated: true) }
                }.placed(14, 95, 252, 75, alignment: .center)
            } else if let selected, let clip = store.items.first(where: { $0.id == selected }) {
                ScrollView {
                    if let image = clip.image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text(clip.text ?? clip.title).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(10).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9)).placed(14, 70, 252, 135)
                Button("К истории") { self.selected = nil }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).placed(14, 214, 100, 28)
                Button { copy(clip) } label: { Text(copied == clip.id ? "✓" : "В буфер").font(.system(size: 10, weight: .medium)).foregroundStyle(.black).frame(width: 109, height: 28).background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 8)) }.offset(x: 157, y: 214)
            } else if store.items.isEmpty {
                Text(store.isPaused ? "История на паузе" : "Скопируй текст или изображение").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).placed(14, 108, 252, 45, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.items) { clip in ClipboardRow(clip: clip, copied: copied == clip.id, open: { selected = clip.id }, copy: { copy(clip) }) }
                    }
                }.scrollIndicators(.hidden).placed(9, 69, 262, 178)
            }
        }.frame(width: 280, height: 253, alignment: .topLeading)
    }
    private func copy(_ clip: Clip) {
        if store.copy(clip) { copied = clip.id; Task { try? await Task.sleep(for: .seconds(1)); if copied == clip.id { copied = nil } } }
        else { model.notify("Не удалось скопировать") }
    }
}

private struct ClipboardRow: View {
    let clip: Clip
    let copied: Bool
    let open: () -> Void
    let copy: () -> Void
    @State private var hovered = false
    private var lines: [String] { (clip.text ?? "Изображение").components(separatedBy: .newlines) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: open) {
                ZStack(alignment: .topLeading) {
                    Image(systemName: clip.image == nil ? "text.alignleft" : "photo").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).placed(8, 3, 12, 12)
                    Text((clip.image == nil ? "Текст" : "Изображение") + " · " + clip.date.formatted(.relative(presentation: .named))).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).placed(24, 1, 199, 12)
                    Text(lines.first ?? clip.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).placed(8, 17, 214, 15)
                    Text(lines.dropFirst().joined(separator: " ")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.58)).lineLimit(1).placed(8, 33, 214, 12)
                }.frame(width: 226, height: 53, alignment: .topLeading).contentShape(Rectangle())
            }
            MiniIcon(symbol: copied ? "checkmark" : "doc.on.doc", label: "Копировать запись", size: 13, action: copy).offset(x: 228, y: 14)
        }.frame(width: 262, height: 53, alignment: .topLeading).background(.white.opacity(hovered || copied ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }
    }
}

private struct ScannerPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var scanner: TextScanner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealStart: Date?
    @State private var revealing = false
    @State private var copied = false
    private var ready: Bool { !scanner.busy && !scanner.text.isEmpty }
    var body: some View {
        ZStack(alignment: .topLeading) {
            PageHeader(title: "Текст со скрина", model: model)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !revealing)) { timeline in
                let elapsed = revealStart.map { timeline.date.timeIntervalSince($0) } ?? 0
                let progress = ready ? (reduceMotion || !revealing ? 1 : TouchMotion.smooth(elapsed / TouchMotion.recognitionDuration)) : 0
                ScanSurface(scanner: scanner, progress: progress, finished: ready && !revealing)
            }.placed(14, 75, 252, 99)
            if scanner.busy {
                Text("Распознавание…").font(.system(size: 9)).foregroundStyle(.white.opacity(0.58)).placed(15, 187, 133, 22)
            } else {
                HStack(spacing: 5) {
                    MiniIcon(symbol: "viewfinder", label: "Новая область экрана", size: 12) { model.captureText() }
                    Button("Из снимка") { model.chooseImage() }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.58))
                }.placed(10, 185, 136, 26)
            }
            Button {
                if ready { scanner.copy(); copied = true; Task { try? await Task.sleep(for: .seconds(1)); copied = false } }
                else { model.captureText() }
            } label: {
                Text(copied ? "✓" : ready ? "В буфер" : scanner.busy ? "Распознавание…" : "Распознать")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(ready || !scanner.busy ? .black : .white.opacity(0.5))
                    .frame(width: 109, height: 30).background(Color(white: scanner.busy ? 0.13 : 0.94), in: RoundedRectangle(cornerRadius: 8))
            }.disabled(scanner.busy || revealing).offset(x: 157, y: 183)
            if let message = scanner.message { Text(message).font(.system(size: 8)).foregroundStyle(.white.opacity(0.58)).lineLimit(1).help(message).placed(14, 216, 252, 12) }
        }.frame(width: 280, height: 229, alignment: .topLeading)
        .onChange(of: scanner.busy) { _, busy in
            if busy { revealStart = nil; revealing = false }
            else if !scanner.text.isEmpty, !reduceMotion {
                revealStart = Date(); revealing = true
                Task { try? await Task.sleep(for: .seconds(TouchMotion.recognitionDuration)); revealing = false }
            }
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { revealing = false } }
    }
}

private struct ScanSurface: View {
    @ObservedObject var scanner: TextScanner
    let progress: Double
    let finished: Bool
    @State private var editing = false
    private var allLines: [String] { scanner.text.components(separatedBy: .newlines).filter { !$0.isEmpty } }
    private var lines: [String] { Array(scanner.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(4)) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            photo
            if progress > 0 {
                Color(white: 0.075).mask(alignment: .top) { revealMask }
                recognized
            }
        }.frame(width: 252, height: 99).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.13), lineWidth: 0.6) }
            .onChange(of: scanner.busy) { _, busy in if busy { editing = false } }
    }
    @ViewBuilder private var photo: some View {
        if let image = scanner.image {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 252, height: 99).clipped()
        } else {
            Color(white: 0.055)
            HStack(spacing: 9) {
                MacIcon(name: "preview", size: 29)
                Text("Текст из любой области экрана").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }.frame(width: 252, height: 99)
        }
    }
    @ViewBuilder private var revealMask: some View {
        if progress >= 1 { Rectangle() }
        else {
            VStack(spacing: 0) {
                Rectangle().frame(height: max(0, progress * 99 - 4))
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 8)
                Spacer(minLength: 0)
            }
        }
    }
    @ViewBuilder private var recognized: some View {
        if finished {
            if editing {
                TextEditor(text: $scanner.text).font(.system(size: 11)).scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 10).accessibilityLabel("Распознанный текст")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(allLines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(size: index == 0 ? 13 : 11, weight: index == 0 ? .medium : .regular))
                                .foregroundStyle(.white.opacity(index == 0 ? 0.95 : 0.76)).frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        }
                    }.padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 10)
                }.scrollIndicators(.hidden).contentShape(Rectangle()).onTapGesture { editing = true }
                    .accessibilityLabel("Распознанный текст").accessibilityHint("Нажми для редактирования")
                    .accessibilityAction(named: Text("Редактировать текст")) { editing = true }
            }
        } else {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                RecognizedLine(line: line, index: index, count: lines.count, progress: progress)
            }
            if progress < 1 { beam }
        }
    }
    private var beam: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.clear, .white.opacity(0.08 * sin(.pi * progress)), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 8).offset(y: progress * 99 - 4)
            Rectangle().fill(.white.opacity(0.16 * sin(.pi * progress))).frame(width: 242, height: 0.3).offset(x: 5, y: progress * 99)
        }
    }
}

private struct RecognizedLine: View {
    let line: String
    let index: Int
    let count: Int
    let progress: Double
    private var threshold: Double { count <= 3 ? [0.43, 0.65, 0.82][min(index, 2)] : 0.27 + Double(index) * 0.18 }
    private var reveal: Double { TouchMotion.smooth((progress - threshold) / 0.1) }
    var body: some View {
        Text(line).font(.system(size: index == 0 ? 13 : 11, weight: index == 0 ? .medium : .regular))
            .foregroundStyle(.white.opacity(index == 0 ? 0.95 : 0.76)).lineLimit(1).opacity(reveal)
            .placed(14, 18 + CGFloat(index) * 22 + CGFloat(2 * (1 - reveal)), 224, 20)
    }
}

private struct FolderRow: View {
    let caption: String?
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                MacIcon(name: "folder").offset(x: 1, y: 4)
                if let caption {
                    Text(caption).font(.system(size: 8)).foregroundStyle(.white.opacity(0.46)).placed(37, 3, 194, 12)
                    Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.82)).lineLimit(1).truncationMode(.middle).placed(37, 16, 194, 15)
                } else {
                    Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle).placed(37, 9, 194, 17)
                }
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).placed(240, 12, 10, 12)
            }.frame(width: 252, height: 36, alignment: .topLeading).contentShape(Rectangle())
        }
    }
}

private struct FormatCarousel: View {
    @ObservedObject var converter: VideoConverter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var position = ScalarMotion()
    private var index: Int { converter.formats.firstIndex(of: converter.format) ?? 0 }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Формат").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).placed(3, 7, 75, 22)
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.14)).frame(width: 48, height: 24).offset(x: 141, y: 4)
            ZStack(alignment: .topLeading) {
                ForEach(Array(converter.formats.enumerated()), id: \.element) { item, label in
                    Button { converter.format = label } label: {
                        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(abs(Double(item) - position.value) < 0.34 ? 0.96 : 0.43))
                            .frame(width: 48, height: 28).contentShape(Rectangle())
                    }.offset(x: 44 + Double(item) * 53 - position.value * 53)
                }
            }.frame(width: 137, height: 28, alignment: .topLeading).clipped().offset(x: 97, y: 2)
            MiniIcon(symbol: "chevron.left", label: "Предыдущий формат", size: 8) { step(-1) }.disabled(index == 0).opacity(index == 0 ? 0.35 : 1).offset(x: 76, y: 6)
            MiniIcon(symbol: "chevron.right", label: "Следующий формат", size: 8) { step(1) }.disabled(index == converter.formats.count - 1).opacity(index == converter.formats.count - 1 ? 0.35 : 1).offset(x: 234, y: 6)
        }.frame(width: 252, height: 34, alignment: .topLeading).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12).onEnded { value in step(value.translation.width < 0 ? 1 : -1) })
            .accessibilityElement(children: .contain).accessibilityLabel("Формат результата").accessibilityValue(converter.format)
            .onAppear { position.set(Double(index), duration: 0) }
            .onChange(of: converter.format) { _, _ in position.set(Double(index), duration: TouchMotion.formatDuration, reduceMotion: reduceMotion) }
            .disabled(converter.running)
    }
    private func step(_ direction: Int) { converter.format = converter.formats[min(converter.formats.count - 1, max(0, index + direction))] }
}

@MainActor
private final class QualityMenu: NSObject {
    let converter: VideoConverter
    init(_ converter: VideoConverter) { self.converter = converter }
    static func present(_ converter: VideoConverter) {
        let target = QualityMenu(converter), menu = NSMenu()
        for quality in VideoQuality.allCases {
            let item = NSMenuItem(title: quality.rawValue, action: #selector(select(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = quality.rawValue
            item.state = converter.quality == quality ? .on : .off
            menu.addItem(item)
        }
        guard let view = NSApp.currentEvent?.window?.contentView ?? NSApp.keyWindow?.contentView else { return }
        let event = NSApp.currentEvent
        let point = event.map { view.convert($0.locationInWindow, from: nil) } ?? NSPoint(x: 235, y: view.bounds.maxY - 155)
        _ = withExtendedLifetime(target) { menu.popUp(positioning: nil, at: point, in: view) }
    }
    @objc private func select(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String, let quality = VideoQuality(rawValue: value) { converter.quality = quality }
    }
}

private struct ConverterPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var converter: VideoConverter
    private var sourceTitle: String {
        guard converter.source != nil else { return "Выбрать файл…" }
        let extensions = Set(converter.inputs.map { $0.pathExtension.uppercased() }).sorted().joined(separator: " / ")
        return "Видео · \(converter.inputs.count)" + (extensions.isEmpty ? "" : " " + extensions)
    }
    private var buttonTitle: String {
        if converter.running { return "Конвертация…" }
        if converter.completedCount > 0, converter.failureCount == 0 { return "Готово · \(converter.completedCount) файлов" }
        return converter.inputs.isEmpty ? "Конвертировать" : "Конвертировать · \(converter.inputs.count)"
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            PageHeader(title: "Конвертация", model: model)
            FolderRow(caption: nil, title: sourceTitle) { model.chooseFolder(destination: false) }
                .help(converter.source?.path ?? "Выбрать видео или папку с видео").disabled(converter.running).offset(x: 14, y: 66)
            FormatCarousel(converter: converter).offset(x: 14, y: 102)
            Button { QualityMenu.present(converter) } label: {
                HStack {
                    Text("Качество").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(converter.quality.rawValue).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                }.padding(.horizontal, 3).frame(width: 252, height: 30).contentShape(Rectangle())
            }.disabled(converter.running).placed(14, 138, 252, 30)
            FolderRow(caption: "Сохранить в", title: converter.destinationFolder?.lastPathComponent ?? "Исходная / Converted") { model.chooseFolder(destination: true) }
                .help(converter.destinationFolder?.path ?? "Выбрать папку результата").disabled(converter.running).offset(x: 14, y: 172)
            Button { converter.running ? converter.cancel() : converter.convert() } label: {
                Text(buttonTitle).font(.system(size: 10, weight: .medium)).foregroundStyle(.black)
                    .frame(width: 252, height: 28).background(.white.opacity(converter.inputs.isEmpty ? 0.35 : 0.94), in: RoundedRectangle(cornerRadius: 8))
            }.disabled(converter.inputs.isEmpty).help(converter.running ? "Остановить конвертацию" : "Конвертировать видео").offset(x: 14, y: 218)
            Text(converter.message ?? (converter.completedCount > 0 ? "Оригиналы сохранены" : ""))
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.53)).lineLimit(1).help(converter.message ?? "").placed(14, 253, 155, 16)
            if converter.running || converter.progress > 0 {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.15))
                    Capsule().fill(.white.opacity(0.9)).frame(width: 92 * converter.progress)
                }.frame(width: 92, height: 3).offset(x: 174, y: 261).accessibilityLabel("Ход конвертации").accessibilityValue("\(Int(converter.progress * 100)) процентов")
            }
        }.frame(width: 280, height: 281, alignment: .topLeading)
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            PageHeader(title: "Touch", model: model)
            Toggle("Запускать при входе", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).controlSize(.small).placed(14, 74, 252, 25)
            Button { model.captures.openFolder() } label: { HStack(spacing: 9) { MacIcon(name: "folder", size: 22); Text("Все снимки в Finder"); Spacer() } }.placed(14, 107, 252, 28)
            Button { model.showSetup?() } label: { HStack(spacing: 9) { Image(systemName: "laptopcomputer").frame(width: 22); Text("Настроить под мой Mac"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 8)) } }.placed(14, 143, 252, 28)
            Text("⌃⌥Пробел — открыть").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).placed(14, 187, 180, 20)
            Button("Выйти") { NSApp.terminate(nil) }.font(.system(size: 10)).placed(217, 183, 49, 28, alignment: .trailing)
        }.frame(width: 280, height: 224, alignment: .topLeading)
    }
}
