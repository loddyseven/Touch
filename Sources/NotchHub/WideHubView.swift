import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor enum NativeArt {
    private static var cache: [String: NSImage] = [:]
    static func resource(_ name: String) -> NSImage {
        if let image = cache[name] { return image }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name).png")
        let image = NSImage(contentsOf: Bundle.main.url(forResource: name, withExtension: "png") ?? local) ?? NSImage()
        cache[name] = image; return image
    }
    static func file(_ url: URL) -> NSImage {
        if let image = cache[url.path] { return image }
        let image: NSImage
        if url.pathExtension == "app", let bundle = Bundle(url: url), let icon = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            image = NSImage(contentsOfFile: url.appendingPathComponent("Contents/Resources/" + icon + (icon.hasSuffix(".icns") ? "" : ".icns")).path) ?? NSWorkspace.shared.icon(forFile: url.path)
        } else { image = NSWorkspace.shared.icon(forFile: url.path) }
        cache[url.path] = image; return image
    }
}

struct TouchSectionIcon: View {
    let tab: HubTab
    var size: CGFloat = 23
    private var emoji: String {
        switch tab {
        case .overview: return "🏠"
        case .files: return "📁"
        case .captures: return "📸"
        case .clipboard: return "🗒️"
        case .converter: return "🎬"
        case .music: return "🎵"
        case .apps: return "🗂️"
        case .scanner: return "🔎"
        }
    }
    var body: some View {
        Text(emoji).font(.custom("Apple Color Emoji", size: size))
            .frame(width: size + 4, height: size + 4).accessibilityHidden(true)
    }
}

struct TouchButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.66 : 1)
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(reduced ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
struct ActionButton: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(primary ? Color.black : .white)
                .background(primary ? Color.white : Color(white: 0.115), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(TouchButtonStyle())
    }
}
struct SmallAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34) }
            .accessibilityLabel(title).help(title).buttonStyle(TouchButtonStyle())
    }
}
struct Suction: ViewModifier {
    var expanded: Bool
    var column: Int
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        content.opacity(expanded ? 1 : 0)
            .scaleEffect(expanded || reduced ? 1 : 0.12, anchor: .top)
            .offset(x: expanded || reduced ? 0 : CGFloat(1 - column) * 92, y: expanded || reduced ? 0 : -62)
            .animation(reduced ? .linear(duration: 0.12) : .spring(response: expanded ? 0.45 : 0.32 + Double(column) * 0.025, dampingFraction: 1), value: expanded)
    }
}

struct HubView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var music: MusicController
    @ObservedObject private var recorder: ScreenRecorder
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var targeted = false
    init(model: AppModel) { self.model = model; self.music = model.music; self.recorder = model.recorder }
    var body: some View {
        ZStack(alignment: .top) {
            WidePanel(model: model)
                .opacity(model.expanded ? 1 : 0)
                .allowsHitTesting(model.expanded).accessibilityHidden(!model.expanded)
            if !model.expanded && recorder.phase.isBusy {
                RecordingNotch(recorder: recorder, notchWidth: model.notchWidth, height: model.notchHeight)
                    .frame(width: model.collapsedWidth).transition(.opacity)
            } else if !model.expanded && music.hasTrack {
                HStack(spacing: 0) {
                    AlbumCover(music: music).frame(width: 23, height: 23).clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: model.notchWidth + 10)
                    MusicWave(spectrum: music.spectrum, active: music.playing, color: Color(nsColor: music.waveColor)).frame(width: 23, height: 18)
                }.padding(.horizontal, 8).frame(width: model.collapsedWidth, height: model.notchHeight)
                .transition(.opacity)
            }
        }
        .frame(width: model.expanded ? model.panelWidth : model.collapsedWidth,
               height: model.expanded ? model.panelHeight : model.notchHeight + 1, alignment: .top)
        .background(Color(nsColor: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)))
        .clipShape(NotchShape(radius: model.expanded ? 26 : 12))
        .overlay {
            if model.expanded || targeted {
                NotchShape(radius: model.expanded ? 26 : 12).stroke(targeted ? Color.blue : Color.white.opacity(0.13), lineWidth: targeted ? 2 : 0.6)
            }
        }
        .animation(reduced ? .linear(duration: 0.12) : .spring(response: model.expanded ? 0.46 : 0.38, dampingFraction: 1), value: model.expanded)
        .animation(reduced ? nil : .easeOut(duration: 0.25), value: model.collapsedWidth)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in receiveFiles(providers) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark).foregroundStyle(.white).tint(.white).buttonStyle(TouchButtonStyle())
    }
    private func receiveFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? URL else { return }
                Task { @MainActor in model.shelf.add([url]); model.tab = .files; model.showPanel?() }
            }
        }
        return !providers.isEmpty
    }
}

struct WidePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: ScreenRecorder
    init(model: AppModel) { self.model = model; self.recorder = model.recorder }
    private let tabs: [HubTab] = [.overview, .files, .captures, .clipboard, .converter, .music, .apps]
    func title(_ tab: HubTab) -> String {
        switch tab {
        case .overview: return model.tr("Главная", "Home")
        case .files: return model.tr("Файлы", "Files")
        case .captures: return model.tr("Снимки", "Captures")
        case .clipboard: return model.tr("Буфер", "Clipboard")
        case .converter: return model.tr("Форматы", "Formats")
        case .music: return model.tr("Музыка", "Music")
        case .apps: return model.tr("Приложения", "Apps")
        case .scanner: return model.tr("Текст со скрина", "Text capture")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchHeight + 7)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(tabs, id: \.self) { tab in
                    Button { withAnimation(.easeOut(duration: 0.2)) { model.tab = tab; model.showingSettings = false } } label: {
                        HStack(spacing: 7) {
                            TouchSectionIcon(tab: tab)
                            Text(title(tab)).font(.system(size: 13, weight: .semibold))
                        }.padding(.horizontal, 11).frame(height: 40)
                            .background(model.tab == tab && !model.showingSettings ? Color(white: 0.155) : .clear, in: RoundedRectangle(cornerRadius: 13))
                    }.accessibilityLabel(title(tab)).help(title(tab))
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).modifier(Suction(expanded: model.expanded, column: 1))
            Group {
                if model.showingSettings { WideSettings(model: model) }
                else {
                    switch model.tab {
                    case .overview: WideHome(model: model)
                    case .files: ShelfModule(model: model, store: model.shelf, compact: false)
                    case .captures: CapturesModule(model: model, store: model.captures)
                    case .clipboard: WideClipboard(model: model, store: model.clipboard)
                    case .converter: WideFormats(model: model, converter: model.converter)
                    case .music: MusicModule(model: model, music: model.music, compact: false)
                    case .apps: AppsModule(model: model, apps: model.pinnedApps, compact: false)
                    case .scanner: WideScanner(model: model, scanner: model.scanner)
                    }
                }
            }.frame(height: model.panelContentHeight, alignment: .top)
                .padding(.horizontal, 24).padding(.top, 14)
            HStack {
                Button { model.showingSettings.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text(model.tr("Настройки", "Settings"))
                    }.font(.system(size: 11)).foregroundStyle(.white.opacity(model.showingSettings ? 1 : 0.6))
                        .frame(height: 24).contentShape(Rectangle())
                }.accessibilityLabel(model.tr("Настройки Touch", "Touch settings"))
                Text(model.toast ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                Spacer()
                if recorder.phase.isBusy { RecordingFooter(recorder: recorder) }
            }.padding(.horizontal, 24).frame(height: 24).padding(.bottom, 7)
        }.frame(width: model.panelWidth, height: model.panelHeight).background(Color.black)
            .preferredColorScheme(.dark).foregroundStyle(.white).tint(.white).buttonStyle(TouchButtonStyle())
    }
}

struct WideHome: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            MusicModule(model: model, music: model.music, compact: true)
                .frame(width: 245).modifier(Suction(expanded: model.expanded, column: 0))
            Divider().overlay(.white.opacity(0.12))
            ShelfModule(model: model, store: model.shelf, compact: true)
                .frame(maxWidth: .infinity).modifier(Suction(expanded: model.expanded, column: 1))
            Divider().overlay(.white.opacity(0.12))
            HomeTools(model: model, clipboard: model.clipboard)
                .frame(width: 180).modifier(Suction(expanded: model.expanded, column: 2))
            Divider().overlay(.white.opacity(0.12))
            AppsModule(model: model, apps: model.pinnedApps, compact: true)
                .frame(width: 104).modifier(Suction(expanded: model.expanded, column: 3))
        }.frame(height: model.panelContentHeight)
    }
}
struct HomeTools: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardStore
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(model.tr("Буфер обмена", "Clipboard")).font(.system(size: 12, weight: .semibold))
            Button { model.tab = .clipboard } label: {
                Text(clipboard.items.first?.title ?? "—")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 35, alignment: .topLeading)
            }
            HStack(spacing: 2) {
                Button { model.tab = .captures; model.captures.refresh() } label: {
                    HStack(spacing: 8) {
                        TouchSectionIcon(tab: .captures, size: 24)
                        Text(model.tr("Снимки", "Captures")).font(.system(size: 12, weight: .semibold))
                    }
                }
                Spacer()
                SmallAction(title: model.tr("Снимок области", "Capture region"), symbol: "plus") { model.captures.capture() }
            }
            Divider().overlay(.white.opacity(0.12))
            Button { model.tab = .converter } label: {
                HStack(spacing: 10) {
                    TouchSectionIcon(tab: .converter, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.tr("Форматы", "Formats")).font(.system(size: 12, weight: .semibold))
                        Text("MP4 · MOV").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)).frame(width: 34, height: 34)
                }
            }
        }
    }
}

struct AlbumCover: View {
    @ObservedObject var music: MusicController
    var body: some View {
        Group {
            if let image = music.artwork { Image(nsImage: image).resizable().scaledToFill() }
            else {
                GeometryReader { geometry in
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(nsImage: NativeArt.file(URL(fileURLWithPath: "/Applications/Яндекс Музыка.app")))
                            .resizable().scaledToFit().padding(geometry.size.width * 0.17)
                    }
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}
struct MusicWave: View {
    @ObservedObject var spectrum: MusicSpectrum
    var active: Bool
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        HStack(alignment: .center, spacing: 1.8) {
            ForEach(0..<SpectrumAnalyzer.bandCount, id: \.self) { i in
                Capsule().fill(color).frame(width: 2.5,
                    height: active && !reduced ? 3 + 20 * spectrum.levels[i] : 3)
            }
        }.frame(height: 24).animation(reduced ? nil : .easeOut(duration: 0.035), value: spectrum.levels)
            .animation(reduced ? nil : .easeOut(duration: 0.4), value: color).accessibilityHidden(true)
    }

}
struct MusicModule: View {
    @ObservedObject var model: AppModel
    @ObservedObject var music: MusicController
    var compact: Bool
    var body: some View {
        if compact {
            centeredPlayer
        } else {
        HStack(alignment: .center, spacing: 22) {
            AlbumCover(music: music).frame(width: 118, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    Text(music.hasTrack ? music.title : model.tr("Яндекс Музыка", "Yandex Music"))
                        .font(.system(size: 22, weight: .semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if music.hasTrack, let liked = music.liked {
                        Button { music.command("like") } label: {
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.system(size: 16)).frame(width: 32, height: 32)
                                .foregroundStyle(liked ? Color(nsColor: music.waveColor) : .white.opacity(0.6))
                        }.accessibilityLabel(model.tr(liked ? "Убрать из любимых в Яндекс Музыке" : "Нравится в Яндекс Музыке", liked ? "Unlike in Yandex Music" : "Like in Yandex Music"))
                            .help(model.tr("Нравится в Яндекс Музыке", "Like in Yandex Music"))
                    }
                }
                if music.hasTrack && !music.artist.isEmpty {
                    Text(music.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                if music.hasTrack {
                    if music.duration > 0 {
                        MusicSeekBar(music: music)
                    }
                    HStack(spacing: 7) {
                        centeredControl(model.tr("Предыдущий трек", "Previous"), symbol: "backward.end.fill", command: "previous")
                        centeredControl(music.playing ? model.tr("Пауза", "Pause") : model.tr("Воспроизвести", "Play"), symbol: music.playing ? "pause.fill" : "play.fill", command: "toggle", prominent: true)
                        centeredControl(model.tr("Следующий трек", "Next"), symbol: "forward.end.fill", command: "next")
                    }.frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Button(music.permissionNeeded ? model.tr("Подключить", "Connect") : model.tr("Открыть плеер", "Open player")) {
                        music.permissionNeeded ? music.connect() : music.openPlayer()
                    }.font(.system(size: 12, weight: .medium)).padding(.top, 3)
                    if !compact && music.permissionNeeded {
                        Text(model.tr("Разреши Touch доступ в «Универсальном доступе», чтобы видеть трек и управлять плеером.", "Allow Touch in Accessibility to see and control your player."))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let message = music.message, !compact { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 166)
            recentTracks.frame(width: 210)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
    private var recentTracks: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.tr("Недавно слушал", "Recently played"))
                Spacer()
                Text("\(music.recentTracks.count)").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 8)
            ForEach(music.recentTracks) { track in
                Button { music.playRecent(track) } label: {
                HStack(spacing: 9) {
                    Group {
                        if let artwork = track.artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                        else { ZStack { Color(white: 0.14); Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)) } }
                    }.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(track.artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if music.startingRecentID == track.id { ProgressView().controlSize(.mini).frame(width: 20) }
                    else if track.duration > 0 { Text(time(track.duration)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(0.4)) }
                }.padding(8).background(track.id == RecentMusicTrack.identity(title: music.title, artist: music.artist) && music.hasTrack ? Color.white.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }.buttonStyle(TouchButtonStyle()).disabled(music.startingRecentID != nil)
                    .accessibilityLabel(model.tr("Воспроизвести ", "Play ") + track.title + ", " + track.artist)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button(model.tr("Скопировать название", "Copy track name")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(track.title + (track.artist.isEmpty ? "" : " — " + track.artist), forType: .string)
                            model.notify(model.tr("Скопировано", "Copied"))
                        }
                    }
            }
            if music.recentTracks.isEmpty {
                Text(model.tr("Пока пусто", "No recent tracks"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(8)
            }
        }.frame(maxHeight: .infinity, alignment: .top).padding(.top, 13)
    }
    private var centeredPlayer: some View {
        VStack(spacing: 0) {
            AlbumCover(music: music).frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 7)
            VStack(spacing: 2) {
                Text(music.hasTrack ? music.title : model.tr("Яндекс Музыка", "Yandex Music"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .help(music.hasTrack ? music.title : "")
                if music.hasTrack && !music.artist.isEmpty {
                    Text(music.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1).help(music.artist)
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(height: 34)
                .padding(.horizontal, 10).padding(.bottom, 7)
            if music.hasTrack {
                MusicSeekBar(music: music, compact: true)
                    .frame(width: 188, height: 25).opacity(music.duration > 0 ? 1 : 0)
                    .accessibilityHidden(music.duration <= 0)
                HStack(spacing: 12) {
                    centeredControl(model.tr("Предыдущий трек", "Previous"), symbol: "backward.fill", command: "previous")
                    centeredControl(music.playing ? model.tr("Пауза", "Pause") : model.tr("Воспроизвести", "Play"), symbol: music.playing ? "pause.fill" : "play.fill", command: "toggle", prominent: true)
                    centeredControl(model.tr("Следующий трек", "Next"), symbol: "forward.fill", command: "next")
                }
            } else {
                Button(music.permissionNeeded ? model.tr("Подключить", "Connect") : model.tr("Открыть плеер", "Open player")) {
                    music.permissionNeeded ? music.connect() : music.openPlayer()
                }.font(.system(size: 12, weight: .medium)).frame(height: 40)
            }
        }.frame(maxWidth: .infinity, alignment: .top)
    }
    private func centeredControl(_ title: String, symbol: String, command: String, prominent: Bool = false) -> some View {
        Button { music.command(command) } label: {
            Image(systemName: symbol).font(.system(size: prominent ? 18 : 15, weight: .medium))
                .offset(x: symbol == "play.fill" ? 1 : 0)
                .frame(width: 40, height: 40)
                .foregroundStyle(prominent && !compact ? Color.black : .white)
                .background(prominent ? Color.white.opacity(compact ? 0.1 : 1) : .clear, in: Circle())
        }.accessibilityLabel(title).help(title).buttonStyle(TouchButtonStyle())
    }
    private func time(_ t: Double) -> String { String(format: "%d:%02d", Int(max(0,t)) / 60, Int(max(0,t)) % 60) }
}

struct ShelfModule: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: FileShelfStore
    var compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.tr("Файлы", "Files")).font(.system(size: compact ? 12 : 20, weight: .semibold))
                Spacer()
                SmallAction(title: model.tr("Добавить файлы", "Add files"), symbol: "plus") { model.chooseShelfFiles() }
                Menu {
                    if !store.selectedURLs.isEmpty {
                        Button { model.notify(store.copySelected() ? model.tr("Файлы скопированы", "Files copied") : model.tr("Файлы недоступны", "Files unavailable")) } label: {
                            Label(model.tr("Скопировать файлы", "Copy files"), systemImage: "doc.on.doc")
                        }
                        Button { model.sendFiles(store.selectedURLs) } label: { Label("AirDrop", systemImage: "airplayaudio") }
                        Button { store.selectedURLs.forEach { NSWorkspace.shared.open($0) } } label: { Label(model.tr("Открыть", "Open"), systemImage: "arrow.up.right.square") }
                        Button { NSWorkspace.shared.activateFileViewerSelecting(store.selectedURLs) } label: { Label(model.tr("Показать в Finder", "Show in Finder"), systemImage: "folder") }
                        Divider()
                        Button { store.removeSelected() } label: { Label(model.tr("Убрать из Touch", "Remove from Touch"), systemImage: "trash") }
                        Divider()
                    }
                    if store.canUndoClear {
                        Button { store.undoClear() } label: { Label(model.tr("Отменить очистку", "Undo clear"), systemImage: "arrow.uturn.backward") }
                    }
                    Button { store.clear() } label: { Label(model.tr("Очистить список файлов", "Clear files list"), systemImage: "trash") }
                        .disabled(store.files.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel(model.tr("Действия с файлами", "File actions"))
            }.frame(height: 24)
            if store.files.isEmpty {
                Button { model.chooseShelfFiles() } label: {
                    VStack(spacing: 9) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 25, weight: .light)).foregroundStyle(.white.opacity(0.5))
                        Text(model.tr("Перетащи файлы сюда", "Drop your files here")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    }.frame(maxWidth: .infinity, minHeight: compact ? 92 : 128)
                        .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3,4])) }
                }
            } else {
                ShelfGallery(model: model, store: store, compact: compact)
                    .frame(height: compact ? 100 : 128)
            }
            HStack {
                if !store.selectedURLs.isEmpty {
                    Text(model.tr("Выбрано: \(store.selectedURLs.count)", "Selected: \(store.selectedURLs.count)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else { Spacer(minLength: 0) }
            }.frame(height: 28)
        }
    }
}

struct AppsModule: View {
    @ObservedObject var model: AppModel
    @ObservedObject var apps: PinnedApps
    var compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.tr("Приложения", "Apps")).font(.system(size: compact ? 12 : 20, weight: .semibold))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 9 : 18), count: compact ? 2 : 8), spacing: 12) {
                    ForEach(Array((compact ? Array(apps.urls.prefix(3)) : apps.urls)), id: \.self) { url in
                        Button { apps.open(url); model.closePanel?() } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: NativeArt.file(url)).resizable().scaledToFit().frame(width: compact ? 40 : 50, height: compact ? 40 : 50)
                                if !compact { Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 11)).lineLimit(1) }
                            }
                        }.help(url.deletingPathExtension().lastPathComponent)
                            .contextMenu { Button(model.tr("Убрать из Touch", "Unpin")) { apps.remove(url) } }
                    }
                    Button { model.chooseApps() } label: { Image(systemName: "plus").font(.system(size: 18, weight: .light)).frame(width: compact ? 40 : 50, height: compact ? 40 : 50).background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 11)) }.help(model.tr("Добавить приложение", "Add app"))
                }
            }.scrollIndicators(.hidden)
        }
    }
}

struct WideClipboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ClipboardStore
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.tr("Буфер обмена", "Clipboard")).font(.system(size: 20, weight: .semibold))
                Spacer()
                SmallAction(title: model.tr("Очистить историю", "Clear history"), symbol: "trash") { store.clear() }
            }
            if store.needsConsent || store.accessDenied {
                Text("Разреши Touch чтение буфера, чтобы сохранять историю копирования.").font(.system(size: 13)).foregroundStyle(.secondary)
                ActionButton(title: "Подключить буфер", symbol: "doc.on.clipboard") {
                    if store.accessDenied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!) }
                    else { store.poll(userInitiated: true) }
                }
            } else if !store.items.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(store.items) { clip in
                                Button { selected = clip.id } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: clip.image == nil ? "text.alignleft" : "photo").frame(width: 22)
                                        Text(clip.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        SmallAction(title: model.tr("Скопировать", "Copy"), symbol: "doc.on.doc") { model.copy(clip) }
                                    }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 48)
                                        .background(selected == clip.id ? Color(white: 0.14) : Color(white: 0.06), in: RoundedRectangle(cornerRadius: 9))
                                }
                            }
                        }
                    }.frame(width: 340)
                    if let clip = store.items.first(where: { $0.id == selected }) ?? store.items.first {
                        VStack(alignment: .leading, spacing: 12) {
                            ScrollView {
                                if let image = clip.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 110) }
                                else { Text(clip.text ?? "").font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }
                            }
                            ActionButton(title: model.tr("Скопировать", "Copy"), symbol: "doc.on.doc", primary: true) { model.copy(clip) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(height: model.panelContentHeight - 46)
            }
        }
    }
}

struct WideFormats: View {
    @ObservedObject var model: AppModel
    @ObservedObject var converter: VideoConverter
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.tr("Форматы", "Formats")).font(.system(size: 20, weight: .semibold))
                Spacer()
                ActionButton(title: model.tr("Выбрать файл", "Choose file"), symbol: "folder") { model.chooseFolder(destination: false) }.disabled(converter.running)
            }
            HStack(spacing: 20) {
                HStack(spacing: 12) {
                    ConverterThumbnail(url: converter.inputs.first)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(converter.inputs.isEmpty ? model.tr("Видео не выбрано", "No video selected") : converter.inputs.count == 1 ? converter.inputs[0].lastPathComponent : "\(converter.inputs.count) " + model.tr("видео", "videos"))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let first = converter.inputs.first {
                            Text(converter.inputs.count > 1 ? first.lastPathComponent + " +\(converter.inputs.count - 1)" : first.pathExtension.uppercased())
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .help(converter.inputs.map(\.lastPathComponent).joined(separator: "\n"))
                Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
                HStack(spacing: 3) {
                    ForEach(converter.formats, id: \.self) { format in
                        Button { converter.format = format } label: {
                            Text(format).font(.system(size: 13, weight: .semibold)).frame(width: 70, height: 36)
                                .foregroundStyle(.white.opacity(converter.format == format ? 1 : 0.55))
                                .background(converter.format == format ? Color(white: 0.22) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.disabled(converter.running).accessibilityAddTraits(converter.format == format ? .isSelected : [])
                    }
                }.padding(4).background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 12))
                Button { converter.running ? converter.cancel() : converter.convert() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: converter.running ? "stop.fill" : "arrow.right")
                        Text(converter.running ? model.tr("Остановить", "Stop") : model.tr("Конвертировать", "Convert"))
                    }.font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 17).frame(height: 44).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }.disabled(converter.inputs.isEmpty)
            }
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
            HStack(spacing: 20) {
                Button { model.chooseFolder(destination: true) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(converter.destination?.lastPathComponent ?? model.tr("Исходная папка / Converted", "Source folder / Converted")).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }.disabled(converter.running).help(converter.destinationFolder?.path ?? "")
                Spacer(minLength: 8)
                Picker(model.tr("Качество", "Quality"), selection: $converter.quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text(model.english ? ($0 == .high ? "High" : $0 == .balanced ? "Balanced" : "Compact") : $0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(width: 194).disabled(converter.running)
            }
            HStack(spacing: 12) {
                if converter.running || converter.progress > 0 {
                    TouchProgress(value: converter.progress).frame(width: 150)
                    Text("\(Int(converter.progress * 100)) %").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let message = converter.message { Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ConverterThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { ZStack { Color(white: 0.1); Image(systemName: "film").font(.system(size: 21)).foregroundStyle(.white.opacity(0.45)) } }
        }.frame(width: 66, height: 48).clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
            .task(id: url) {
                image = nil
                guard let url else { return }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 160, height: 120)
                guard let (frame, _) = try? await generator.image(at: .zero), !Task.isCancelled else { return }
                image = NSImage(cgImage: frame, size: .zero)
            }
    }
}
struct WideScanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject var scanner: TextScanner
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 17) {
                Text(model.tr("Текст со скрина", "Text capture")).font(.system(size: 22, weight: .semibold))
                ActionButton(title: model.tr("Выделить область", "Capture region"), symbol: "text.viewfinder", primary: true) { model.captureText() }
                ActionButton(title: model.tr("Выбрать изображение", "Choose image"), symbol: "photo") { model.chooseImage() }
                if scanner.busy { ProgressView() }
                if let message = scanner.message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.frame(width: 290)
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $scanner.text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(10).background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
                ActionButton(title: model.tr("Скопировать текст", "Copy text"), symbol: "doc.on.doc") { scanner.copy(); model.notify(model.tr("Скопировано", "Copied")) }.disabled(scanner.text.isEmpty)
            }
        }.frame(height: model.panelContentHeight)
    }
}
struct WideSettings: View {
    @ObservedObject var model: AppModel
    @State private var musicSection = false
    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.tr("Настройки", "Settings")).font(.system(size: 20, weight: .semibold)).padding(.bottom, 12)
                category(model.tr("Основные", "General"), symbol: "slider.horizontal.3", music: false)
                category(model.tr("Музыка", "Music"), symbol: "music.note", music: true)
            }.frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(musicSection ? model.tr("Музыка", "Music") : model.tr("Основные", "General"))
                    .font(.system(size: 14, weight: .semibold)).frame(height: 24)
                VStack(spacing: 0) {
                    if musicSection {
                        setting(model.tr("Яндекс Музыка", "Yandex Music"), symbol: "music.note", value: model.music.permissionNeeded ? model.tr("Подключить", "Connect") : model.tr("Подключена", "Connected")) { model.music.connect() }
                        Divider().overlay(.white.opacity(0.04)).padding(.leading, 14)
                        setting(model.tr("Открыть плеер", "Open player"), symbol: "play.rectangle", value: "") { model.music.openPlayer() }
                    } else {
                        HStack(spacing: 11) {
                            Image(systemName: "power").frame(width: 18).foregroundStyle(.white.opacity(0.65))
                            Toggle(model.tr("Запускать при входе", "Launch at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).toggleStyle(.switch).controlSize(.small).tint(.green)
                        }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 42)
                        Divider().overlay(.white.opacity(0.04)).padding(.leading, 14)
                        setting(model.tr("Настроить под мой Mac", "Set up for my Mac"), symbol: "laptopcomputer", value: "") { model.showSetup?() }
                        Divider().overlay(.white.opacity(0.04)).padding(.leading, 14)
                        setting(model.tr("Папка снимков", "Capture folder"), symbol: "folder", value: model.tr("Открыть в Finder", "Open in Finder")) { model.captures.openFolder() }
                    }
                }.background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 12))
                Button(model.tr("Завершить Touch", "Quit Touch")) { NSApp.terminate(nil) }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).frame(height: 24)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, 3)
    }
    private func category(_ title: String, symbol: String, music: Bool) -> some View {
        Button { musicSection = music } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).frame(height: 36)
                .background(musicSection == music ? Color(white: 0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityAddTraits(musicSection == music ? .isSelected : [])
    }
    private func setting(_ title: String, symbol: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.white.opacity(0.65))
                Text(title); Spacer()
                Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }
            .font(.system(size: 12)).padding(.horizontal, 14).frame(height: 42).contentShape(Rectangle())
        }
    }
}

struct TouchProgress: View {
    var value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.9)).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }.frame(height: 4).accessibilityLabel("Прогресс").accessibilityValue("\(Int(min(1, max(0, value)) * 100))%")
    }
}

struct MusicSeekBar: View {
    @ObservedObject var music: MusicController
    var compact = false
    @State private var scrubPosition: Double?
    @State private var scrubTrack = ""
    private var track: String { music.title + "|" + music.artist }
    private var position: Double { scrubPosition ?? music.elapsed }
    private func timestamp(_ value: Double) -> String {
        let seconds = Int(max(0, value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { min(max(0, position), max(1, music.duration)) }, set: {
                if scrubPosition == nil { scrubTrack = track }
                scrubPosition = $0
            }), in: 0...max(1, music.duration), onEditingChanged: { editing in
                music.isScrubbing = editing
                if editing { scrubTrack = track }
                else {
                    if scrubTrack == track, let target = scrubPosition { music.seek(to: target) }
                    scrubPosition = nil
                }
            }).controlSize(.small).tint(.white).disabled(!music.canSeek)
                .accessibilityLabel("Перемотка трека")
                .accessibilityValue("\(timestamp(position)) из \(timestamp(music.duration))")
            HStack {
                Text(timestamp(position))
                Spacer()
                Text(timestamp(music.duration))
            }.font(.system(size: compact ? 9 : 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
        }.onChange(of: track) { _, _ in scrubPosition = nil; music.isScrubbing = false }
            .onDisappear { music.isScrubbing = false }
    }
}
