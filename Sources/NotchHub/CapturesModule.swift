import SwiftUI
import AppKit

struct CapturesModule: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: CaptureStore
    @ObservedObject private var recorder: ScreenRecorder
    @State private var showsCaptureMenu = false
    init(model: AppModel, store: CaptureStore) {
        self.model = model; self.store = store; self.recorder = model.recorder
    }
    private var videoMode: Bool { recorder.showsSetup || recorder.phase.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: videoMode ? 11 : 10) {
            header
            if videoMode {
                RecordingControls(recorder: recorder)
                status.frame(height: 34)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    actions
                    VStack(spacing: 8) {
                        gallery
                        selectionFooter
                    }
                }.frame(height: 168)
            }
        }.onAppear { store.refresh() }
            .onChange(of: showsCaptureMenu) { _, showing in model.isShowingCaptureMenu = showing }
            .onDisappear { model.isShowingCaptureMenu = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(videoMode ? model.tr("Запись экрана", "Screen recording") : model.tr("Снимки", "Captures"))
                .font(.system(size: 20, weight: .semibold))
            if !videoMode {
                Text("\(store.items.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if videoMode && !recorder.phase.isBusy {
                Button { recorder.showsSetup = false } label: {
                    Label(model.tr("К снимкам", "Back to captures"), systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            libraryMenu
        }.frame(height: videoMode ? 34 : 26)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { showsCaptureMenu = true } label: {
                actionTile(title: model.tr("Снимок", "Screenshot"), symbol: "viewfinder", primary: true)
            }.buttonStyle(TouchButtonStyle())
                .accessibilityLabel(model.tr("Снимок — выбрать область, окно или текст", "Screenshot — choose region, window or text"))
                .disabled(store.isCapturing)
                .popover(isPresented: $showsCaptureMenu, arrowEdge: .trailing) {
                    VStack(spacing: 2) {
                        captureChoice(model.tr("Область", "Region"), symbol: "viewfinder") { store.capture() }
                        captureChoice(model.tr("Окно", "Window"), symbol: "macwindow") { store.capture(window: true) }
                        captureChoice(model.tr("Текст со скрина", "Capture text"), symbol: "text.viewfinder") { model.captureText() }
                    }.padding(6).frame(width: 202).preferredColorScheme(.dark)
                }
            Button { recorder.showsSetup = true } label: {
                actionTile(title: model.tr("Видео", "Video"), symbol: "record.circle", primary: false)
            }.disabled(store.isCapturing)
                .accessibilityLabel(model.tr("Записать видео экрана", "Record screen video"))
        }.frame(width: 128)
    }

    private func captureChoice(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            showsCaptureMenu = false
            model.isShowingCaptureMenu = false
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(TouchButtonStyle())
    }

    private func actionTile(title: String, symbol: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                    .foregroundStyle(primary ? Color.black : Color.red)
                Spacer()
            }
            Text(title).font(.system(size: 13, weight: .semibold))
        }.padding(.horizontal, 14).frame(width: 128, height: 79)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(primary ? Color.white : Color(white: 0.09), in: RoundedRectangle(cornerRadius: 13))
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder private var gallery: some View {
        if store.items.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 24, weight: .light))
                Text(model.tr("Здесь появятся снимки и видео", "Your screenshots and videos appear here"))
                    .font(.system(size: 12))
            }.foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity).frame(height: 132)
                .background(Color(white: 0.035), in: RoundedRectangle(cornerRadius: 12))
        } else {
            GeometryReader { geometry in
                let columns = max(1, Int(geometry.size.width / 150))
                let width = max(80, (geometry.size.width - 12 - CGFloat(columns - 1) * 10) / CGFloat(columns))
                CaptureGallery(store: store, tileSize: NSSize(width: width, height: 55), rows: 2,
                    selectionMenu: { SelectionActionsMenu.captures(model: model, store: store) })
            }.frame(height: 132)
        }
    }

    private var libraryMenu: some View {
        Menu {
            if !videoMode && !store.selectedCaptures.isEmpty {
                Button { store.copySelected() } label: { Label(model.tr("Скопировать", "Copy"), systemImage: "doc.on.doc") }
                Button { model.sendSelected() } label: { Label("AirDrop", systemImage: "airplayaudio") }
                Button { store.selectedCaptures.forEach { NSWorkspace.shared.open($0.url) } } label: {
                    Label(model.tr("Открыть", "Open"), systemImage: "arrow.up.right.square")
                }
                if store.selectedCaptures.count == 1, let capture = store.selectedCaptures.first, !capture.isVideo {
                    Button { model.tab = .scanner; model.scanner.recognize(capture.url) } label: {
                        Label(model.tr("Распознать текст", "Recognize text"), systemImage: "text.viewfinder")
                    }
                }
                Divider()
                Button { store.removeSelected() } label: { Label(model.tr("Убрать из Touch", "Remove from Touch"), systemImage: "trash") }
                Divider()
            }
            Button { store.openFolder() } label: { Label(model.tr("Показать папку", "Show folder"), systemImage: "folder") }
            if !videoMode {
                Button { store.selectAll() } label: { Label(model.tr("Выбрать все", "Select all"), systemImage: "checkmark.circle") }
                    .disabled(store.items.isEmpty)
                Divider()
                if store.canUndoClear {
                    Button { store.undoClear() } label: { Label(model.tr("Отменить очистку", "Undo clear"), systemImage: "arrow.uturn.backward") }
                }
                Button { store.clear() } label: { Label(model.tr("Очистить список снимков", "Clear captures list"), systemImage: "trash") }
                    .disabled(store.items.isEmpty || store.isCapturing)
                    .help(model.tr("Оригиналы останутся в папке", "Original files stay in their folder"))
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(model.tr("Управление снимками", "Manage captures"))
    }

    private var selectionFooter: some View {
        HStack(spacing: 12) {
            if !store.selectedCaptures.isEmpty {
                Text(store.selectedCaptures.count == 1 ? store.selectedCaptures[0].url.lastPathComponent : model.tr("Выбрано: \(store.selectedCaptures.count)", "Selected: \(store.selectedCaptures.count)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else { Spacer(minLength: 0) }
            status
        }.frame(height: 28)
    }

    private var status: some View {
        HStack(spacing: 8) {
            if let message = recorder.message ?? store.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if recorder.needsPermission || store.needsPermissionHelp {
                Button(model.tr("Разрешить запись экрана", "Screen recording access")) { store.openPermissions() }
                    .font(.system(size: 11))
            }
            if store.needsFolderPermissionHelp {
                Button(model.tr("Доступ к папке снимков", "Screenshot folder access")) { store.openFolderPermissions() }
                    .font(.system(size: 11))
            }
        }
    }
}
