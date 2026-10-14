import AppKit
import SwiftUI

struct NativeDeviceScreen: View {
    @ObservedObject var model: NativeMacModel
    @State private var resetSerial: String?
    @State private var showingResetConfirmation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScreenTitle(title: VL.text("Устройство"), subtitle: model.autoSyncInterval.keepsConnection ? VL.text("Постоянное подключение к Plaud включено."):VL.text("Подключение по запросу. После синхронизации Bluetooth освобождается."))
                HStack(spacing: 24) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 54)).foregroundColor(Ink.secondary).frame(width: 110, height: 140)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.savedDevice?.model.displayName ?? VL.text("Подключите Plaud")).font(.system(size: 24, weight: .semibold))
                        Label(model.connected ? VL.text("Подключён") : (model.savedDevice == nil ? VL.text("Устройство не выбрано") : VL.text("Готов к синхронизации")), systemImage: "circle.fill")
                            .font(.system(size: 12)).foregroundColor(model.connected ? Ink.success : Ink.secondary)
                        if let serial = model.savedDevice?.serialNumber { Text(VL.text("Серийный номер: ••••") + String(serial.suffix(4))).font(.system(size: 12)).foregroundColor(Ink.muted) }
                        Button(model.savedDevice == nil ? VL.text("Подключить Plaud") : VL.text("Синхронизировать"), action: model.refresh).buttonStyle(QuietButton(primary: true)).disabled(model.busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Ink.surface).cornerRadius(9)
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.offlineAuthorizationReady ? VL.text("Локальная авторизация сохранена") : VL.text("Первоначальная авторизация через PLAUD"), systemImage: model.offlineAuthorizationReady ? "lock.shield" : "key")
                    Text(VL.text("После успешной настройки последующие подключения используют ключи из Связки ключей macOS без обращения к PLAUD API. После сброса или смены привязки может понадобиться повторная настройка.")).font(.caption).foregroundColor(Ink.secondary)
                    Button(VL.text("Настройка авторизации…"), action: model.beginDeviceSetup).disabled(model.busy)
                }.padding(20).background(Ink.surface).cornerRadius(9)
                VStack(spacing: 18) {
                    if let battery = model.battery { line(model.connected ? VL.text("Заряд") : VL.text("Последний известный заряд"), "\(battery)%") }
                    if let date = model.savedDevice?.lastSynchronized { line(VL.text("Последняя синхронизация"), date.vectaFormatted(date: .abbreviated, time: .shortened)) }
                    line(VL.text("Записей на Mac"), "\(model.library?.localItemCount ?? 0)")
                }.padding(20).background(Ink.surface).cornerRadius(9)
                HStack(spacing: 12) {
                    if model.savedDevice != nil { Button(VL.text("Подключить другой Plaud"), action: model.scan).buttonStyle(QuietButton()).disabled(model.busy) }
                    if model.busy || model.connected { Button(model.resettingDevice ? VL.text("Остановить ожидание") : VL.text("Отключить"), action: model.disconnect).buttonStyle(QuietButton()) }
                }
                if model.savedDevice?.model == .notePinS && model.savedDevice?.protocolVersion == 20 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(VL.text("Удаление Plaud")).font(.system(size: 15, weight: .semibold))
                        Text(NativeFactoryResetCopy.explanation).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                        Button(VL.text("Удалить Plaud"), role: .destructive) {
                            resetSerial = model.savedDevice?.serialNumber
                            showingResetConfirmation = resetSerial != nil
                        }.disabled(!model.canFactoryReset)
                    }.padding(20).background(Ink.surface).cornerRadius(9)
                }
                Text(model.status).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                Text(VL.text("Обычная синхронизация не удаляет записи на PLAUD. Сброс запускается только после отдельного подтверждения."))
                    .font(.system(size: 12)).foregroundColor(Ink.muted).lineSpacing(4)
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }.alert(VL.text("Удалить Plaud ••••\(resetSerial.map { String($0.suffix(4)) } ?? "")?"), isPresented: $showingResetConfirmation) {
            Button(VL.text("Отмена"), role: .cancel) { resetSerial = nil }
            Button(VL.text("Удалить Plaud"), role: .destructive) {
                guard let serial = resetSerial else { return }
                resetSerial = nil
                model.factoryReset(confirmedSerial: serial)
            }.disabled(!model.canFactoryReset || resetSerial != model.savedDevice?.serialNumber)
        } message: {
            Text(NativeFactoryResetCopy.confirmation)
        }
    }
    private func line(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundColor(Ink.secondary); Spacer(); Text(value) }.font(.system(size: 13)) }
}

struct NativeFormatsScreen: View {
    @ObservedObject var model:NativeMacModel
    @ObservedObject var library: NativeLibraryController
    @State private var formatSection=0
    @State private var editing: VectaSummaryInterpretation?
    @State private var showingEditor = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    ScreenTitle(title: VL.text("Форматы саммари"), subtitle: VL.text("Четыре уровня подробности и независимые шаблоны структуры."))
                    if formatSection==1 { Button { editing = nil; showingEditor = true } label: { Label(VL.text("Новый формат"), systemImage: "plus") }.buttonStyle(QuietButton(primary: true)) }
                }
                VectaSegmentedControl(label:VL.text("Раздел форматов"),choices:[VectaChoice(id:0,title:VL.text("Шаблоны структуры")),VectaChoice(id:1,title:VL.text("Подробность"))],selection:$formatSection)
                if formatSection==0 {NativeTemplateSettings(model:model)} else {
                VStack(spacing: 1) {
                    ForEach(NativeSummaryCatalog.visible(library.formats)) { format in
                        HStack(spacing: 14) {
                            Image(systemName: format.id == "detailed" ? "text.justify" : "text.alignleft").font(.system(size: 18)).frame(width: 40, height: 40).background(Ink.elevated).cornerRadius(8)
                            VStack(alignment: .leading, spacing: 6) { Text(format.displayTitle).font(.system(size: 15, weight: .medium)); Text(format.detail).font(.system(size: 12)).foregroundColor(Ink.muted).lineLimit(2) }
                            Spacer(minLength: 4)
                            Menu {
                                Button(VL.text("Редактировать")) { editing = format; showingEditor = true }
                                if !format.isBuiltin { Button(VL.text("Удалить формат"), role: .destructive) { do { try library.deleteFormat(format) } catch { self.error = error.localizedDescription } } }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help(VL.text("Действия с форматом"))
                        }.padding(18).background(Ink.surface)
                    }
                }.cornerRadius(9)
                if !library.deletedFormats.isEmpty {
                    DisclosureGroup(VL.text("Удалённые форматы")) {
                        ForEach(library.deletedFormats) { format in
                            HStack { Text(format.displayTitle); Spacer(); Button(VL.text("Восстановить")) { do { try library.restoreFormat(format) } catch { self.error = error.localizedDescription } } }.padding(.vertical, 8)
                        }
                    }.foregroundColor(Ink.secondary).font(.system(size: 12))
                }
                Text(VL.text("Изменения применяются к новым запросам. Ранее созданные саммари сохраняют исходную инструкцию и её версию.")).font(.system(size: 12)).foregroundColor(Ink.muted).lineSpacing(4)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }.sheet(isPresented: $showingEditor) { NativeFormatEditor(library: library, original: editing) }.onAppear {model.loadWorkspace()}
    }
}

struct NativeFormatEditor: View {
    @ObservedObject var library: NativeLibraryController
    let original: VectaSummaryInterpretation?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(title: original == nil ? VL.text("Новый формат") : VL.text("Редактировать формат"))
            Text(VL.text("Название")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            TextField(VL.text("Например, рабочая встреча"), text: $title).textFieldStyle(.plain).padding(12).background(Ink.elevated).cornerRadius(7)
            Text(VL.text("Инструкция для саммари")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            TextEditor(text: $prompt).accessibilityLabel(VL.text("Инструкция для саммари")).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).background(Ink.elevated).cornerRadius(7).frame(minHeight: 220)
            Text(VL.text("Опишите, что выделить в записи и как оформить результат. Не просите модель дополнять неизвестные факты.")).font(.system(size: 12)).foregroundColor(Ink.muted)
            if let error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }
            HStack { Spacer(); Button(VL.text("Отмена")) { dismiss() }.buttonStyle(QuietButton()); Button(VL.text("Сохранить")) {
                do {
                    if let original { try library.updateFormat(original, title: title, prompt: prompt) }
                    else { _ = try library.createFormat(title: title, prompt: prompt) }
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(QuietButton(primary: true)).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 580).background(Ink.canvas).foregroundColor(Ink.text)
            .onAppear { title = original?.title ?? ""; prompt = original?.prompt ?? "" }
    }
}

/// Recording and queue read the same host-owned state, not independent view timers.
