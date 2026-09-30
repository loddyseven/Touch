import SwiftUI

struct RecordingControls: View {
    @ObservedObject var recorder: ScreenRecorder
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Group {
            if recorder.phase.isBusy {
                activeControls            } else {
                setupControls
            }
        }.frame(height: 114).buttonStyle(TouchButtonStyle())
            .animation(reduced ? nil : .easeOut(duration: 0.18), value: recorder.phase)
    }
    private var activeControls: some View {
                HStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.12)).frame(width: 64, height: 64)
                        Image(systemName: recorder.phase == .finishing ? "checkmark" : "record.circle")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(primaryText).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(statusText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if recorder.phase.canStop {
                        Button { recorder.stop() } label: {
                            Label(recorder.phase == .recording ? "Остановить" : "Отменить", systemImage: recorder.phase == .recording ? "stop.fill" : "xmark")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                                .frame(width: 154, height: 42).background(.white, in: RoundedRectangle(cornerRadius: 11))
                        }.keyboardShortcut(.escape, modifiers: [])
                    } else { ProgressView().controlSize(.small).padding(.trailing, 65) }
                }.padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 16))

    }
    private var setupControls: some View {
                HStack(spacing: 12) {
                    target(.screen, title: "Весь экран", symbol: "display")
                    target(.region, title: "Область", symbol: "viewfinder")
                    Spacer(minLength: 22)
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $recorder.capturesAudio) {
                            Label("Звук Mac", systemImage: recorder.capturesAudio ? "speaker.wave.2" : "speaker.slash")
                                .font(.system(size: 12, weight: .medium))
                        }.toggleStyle(.switch).controlSize(.small).tint(.green)
                        Text("MP4 · 60 кадров/с").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }.frame(width: 170)
                    Spacer(minLength: 10)
                    Button { recorder.request() } label: {
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text(recorder.mode == .region ? "Выбрать область" : "Начать запись").font(.system(size: 13, weight: .semibold))
                        }.foregroundStyle(.black).frame(width: 176, height: 42)
                            .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    }.accessibilityHint("После выбора начнётся обратный отсчёт на три секунды")
                }
    }
    private func target(_ mode: ScreenRecorder.Mode, title: String, symbol: String) -> some View {
        Button { recorder.mode = mode } label: {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 26, weight: .light))
                Text(title).font(.system(size: 12, weight: .medium))
            }.frame(width: 140, height: 112)
                .foregroundStyle(recorder.mode == mode ? Color.white : Color.white.opacity(0.5))
                .background(Color(white: recorder.mode == mode ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(recorder.mode == mode ? 0.65 : 0.07), lineWidth: 1) }
        }.accessibilityAddTraits(recorder.mode == mode ? .isSelected : [])
    }
    private var primaryText: String {
        switch recorder.phase {
        case .countdown(let number): return "\(number)"
        case .preparing: return "Старт…"
        case .finishing: return recorder.clock
        default: return recorder.clock
        }
    }
    private var statusText: String {
        switch recorder.phase {
        case .countdown: return "До начала записи"
        case .preparing: return "Подготовка записи"
        case .finishing: return "Сохраняем видео…"
        default: return recorder.capturesAudio ? "Идёт запись · со звуком Mac" : "Идёт запись · без звука"
        }
    }
}

struct RecordingFooter: View {
    @ObservedObject var recorder: ScreenRecorder
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(recorder.phase == .finishing ? "Сохраняем…" : recorder.clock).monospacedDigit()
            if recorder.phase.canStop {
                Button { recorder.stop() } label: {
                    Label(recorder.phase == .recording ? "Остановить" : "Отменить", systemImage: recorder.phase == .recording ? "stop.fill" : "xmark")
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(TouchButtonStyle())
            }
        }.font(.system(size: 11, weight: .medium))
    }
}

struct RecordingNotch: View {
    @ObservedObject var recorder: ScreenRecorder
    var notchWidth: CGFloat
    var height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hoveringStop = false

    private var displayTime: String {
        if case .countdown(let seconds) = recorder.phase { return String(format: "00:%02d", seconds) }
        return recorder.clock
    }
    private var actionTitle: String {
        recorder.phase == .recording ? "Остановить и сохранить запись" : "Отменить запись"
    }
    var body: some View {
        HStack(spacing: 0) {
            Text(displayTime)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.56))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(width: NotchGeometry.recordingWingWidth)
                .accessibilityLabel(recorder.phase == .recording ? "Запись экрана, \(recorder.clock)" : "До записи \(displayTime)")
            Color.clear.frame(width: notchWidth + 2, height: height).accessibilityHidden(true)
            Group {
                if recorder.phase.canStop {
                    Button { recorder.stop() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(white: hoveringStop ? 0.22 : 0.145))
                                .frame(width: 23, height: 23)
                            if recorder.phase == .recording {
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 7, height: 7)
                            } else {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white)
                            }
                        }.frame(width: NotchGeometry.recordingWingWidth, height: height).contentShape(Rectangle())
                    }
                    .buttonStyle(TouchButtonStyle()).help(actionTitle).accessibilityLabel(actionTitle)
                    .onHover { hoveringStop = $0 }
                } else {
                    ProgressView().controlSize(.mini)
                        .frame(width: NotchGeometry.recordingWingWidth, height: height)
                        .accessibilityLabel(recorder.phase == .finishing ? "Сохраняем запись" : "Подготовка записи")
                }
            }
        }.frame(height: height)
            .accessibilityElement(children: .contain)
            .animation(reduced ? nil : .easeOut(duration: 0.14), value: hoveringStop)
    }
}
