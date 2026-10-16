import AppKit
import Combine
import SwiftUI

struct NativeMacRecordingDisplay {
    let phase: NativeMacRecorder.Phase
    let elapsed: TimeInterval
    var recording: Bool { phase == .recording }
    var busy: Bool { phase != .idle }
    var clock: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

@MainActor final class NativeMacRecordingMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private weak var model: NativeMacModel?
    private let recorder: NativeMacRecorder
    private let preferences: NativeMacRecordingPreferences
    private let showWindow: () -> Void
    private var changes: AnyCancellable?
    init(model: NativeMacModel, showWindow: @escaping () -> Void) {
        self.model = model; recorder = model.macRecorder; preferences = model.macRecordingPreferences; self.showWindow = showWindow
        super.init()
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        popover.behavior = .transient; popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)
        let controller = NSHostingController(rootView: NativeMacRecordingCard(model: model,
            open: { [weak self] in self?.popover.performClose(nil); self?.showWindow() },
            settings: { [weak self] in self?.openConferences() }))
        controller.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        popover.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width: 352, height: max(360, controller.view.fittingSize.height))
        changes = recorder.objectWillChange.merge(with: preferences.objectWillChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }
    private func refresh() {
        item.isVisible = preferences.value.showMenuIcon
        if !item.isVisible { popover.performClose(nil) }
        let active = recorder.phase == .recording
        item.button?.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "waveform.circle", accessibilityDescription: "Vecta")
        item.button?.contentTintColor = active ? .systemRed : nil
        item.button?.title = active && preferences.value.showElapsed ? String(format: " %02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60) : ""
        item.button?.toolTip = active ? VL.text("Vecta — идёт запись звука") : VL.text("Vecta — запись звука с Mac")
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func openConferences() {
        popover.performClose(nil); model?.destination = .conferences; showWindow()
    }
}

struct NativeMacRecordingCard: View {
    @ObservedObject var model: NativeMacModel
    @ObservedObject var recorder: NativeMacRecorder
    @ObservedObject var preferences: NativeMacRecordingPreferences
    let display: NativeMacRecordingDisplay?
    let open: () -> Void
    let settings: () -> Void
    private let red = Color(red: 0.86, green: 0.13, blue: 0.19)
    private let secondary = Color(red: 0.44, green: 0.46, blue: 0.50)
    init(model: NativeMacModel, display: NativeMacRecordingDisplay? = nil, open: @escaping () -> Void, settings: @escaping () -> Void) {
        self.model = model; recorder = model.macRecorder; preferences = model.macRecordingPreferences
        self.display = display; self.open = open; self.settings = settings
    }
    private var state: NativeMacRecordingDisplay { display ?? .init(phase: recorder.phase, elapsed: recorder.elapsed) }
    private var mode: NativeMacRecordingMode { state.busy && display == nil ? recorder.mode : preferences.value.mode }
    private var needsApplication: Bool { mode == .application && preferences.value.conferenceApplicationID.isEmpty }
    private var canStart: Bool { display != nil || (model.library != nil && !model.importingAudio && model.purgingRecording == nil && !needsApplication) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
                    Text("VECTA").font(.system(size: 11, weight: .bold)).tracking(2.5)
                }
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain).vectaFocusStyle().foregroundColor(secondary)
                    .background(Color.black.opacity(0.04)).cornerRadius(9)
                    .help(VL.text("Настройки конференций")).accessibilityLabel(VL.text("Настройки конференций"))
            }
            if state.recording {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Circle().fill(red).frame(width: 7, height: 7)
                        Text("REC").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.4)
                    }.foregroundColor(red).accessibilityLabel(VL.text("Идёт запись"))
                    Spacer()
                    Text(state.clock).font(.system(size: 27, weight: .medium, design: .monospaced)).monospacedDigit()
                }
                Text(VL.text("Идёт запись")).font(.system(size: 13)).foregroundColor(red)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(VL.text("Начать запись")).font(.system(size: 25, weight: .semibold))
                    Text(state.phase == .starting ? VL.text("Ожидание разрешения macOS…") : state.phase == .saving ? VL.text("Сохраняем аудиозапись…") : VL.text("Встреча или голос. Только на этом Mac."))
                        .font(.system(size: 12)).foregroundColor(secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(VL.text("Источник звука")).font(.system(size: 11, weight: .medium)).foregroundColor(secondary)
                Menu {
                    ForEach(NativeMacRecordingMode.allCases, id: \.rawValue) { source in
                        Button { preferences.value.mode = source } label: { Label(source.title, systemImage: source.symbol) }
                    }
                } label: {
                    Label(mode.title, systemImage: mode.symbol).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .padding(.trailing, 16).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.black.opacity(0.035)).cornerRadius(11)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundColor(secondary).padding(.trailing, 12).allowsHitTesting(false)
                    }.disabled(state.busy)
                if mode == .application {
                    Button(action: settings) {
                        Text(needsApplication ? VL.text("Выберите приложение в настройках") : (NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferences.value.conferenceApplicationID)?.deletingPathExtension().lastPathComponent ?? preferences.value.conferenceApplicationID))
                            .font(.system(size: 11)).foregroundColor(secondary).lineLimit(1)
                    }.buttonStyle(.plain)
                }
            }
            Button {
                guard display == nil else { return }
                if state.recording { Task { await recorder.stop() } }
                else if state.phase == .idle { model.startMacRecording(preferences.value.mode) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: state.recording ? "stop.fill" : "record.circle.fill")
                        .foregroundColor(state.recording ? .white : red)
                    Text(state.recording ? VL.text("Остановить и сохранить") : VL.text("Начать запись"))
                        .font(.system(size: 14, weight: .semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 14)
                    .foregroundColor(.white).background(state.recording ? red : Color.black).cornerRadius(12)
                    .opacity((state.phase == .idle && !canStart) || (state.busy && !state.recording) ? 0.45 : 1)
            }.buttonStyle(.plain).disabled((state.phase == .idle && !canStart) || (state.busy && !state.recording))
            if display == nil, !recorder.message.isEmpty {
                Text(recorder.message).font(.system(size: 11)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(action: open) {
                    Label(VL.text("Открыть Vecta"), systemImage: "arrow.up.forward.app").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(secondary)
                Spacer()
                Menu {
                    Button(VL.text("Несохранённые записи…")) {
                        let root = model.services.appendingPathComponent("MacRecordings", isDirectory: true)
                        if FileManager.default.fileExists(atPath: root.path) { NSWorkspace.shared.open(root) }
                    }
                    Button(VL.text("Завершить Vecta")) { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 18).foregroundColor(secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }.padding(22).frame(width: 336).foregroundColor(Color.black)
            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(state.recording ? red : Color.black.opacity(0.08), lineWidth: state.recording ? 3 : 1))
            .padding(8).background(Color.white).preferredColorScheme(.light).vectaFocusStyle()
    }
}
