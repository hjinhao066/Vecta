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

private enum NativeFormatEditingTarget: Identifiable {
    case new, edit(VectaSummaryInterpretation), duplicate(NativeSummaryRecipe), legacy(AISummaryTemplate)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let format): return "edit:" + format.id
        case .duplicate(let recipe): return "copy:" + recipe.id
        case .legacy(let template): return "legacy:" + template.id
        }
    }
}

struct NativeFormatsScreen: View {
    @ObservedObject var model: NativeMacModel
    @ObservedObject var library: NativeLibraryController
    @State private var editing: NativeFormatEditingTarget?
    @State private var deleting: VectaSummaryInterpretation?
    @State private var error: String?
    private var recipes: [NativeSummaryRecipe] {
        NativeSummarySelection.recipes(formats: NativeSummaryCatalog.visible(library.formats), templates: model.currentSummaryTemplates)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    ScreenTitle(title: VL.text("Форматы саммари"), subtitle: VL.text("Выберите встроенный формат или создайте свой: название и инструкция для саммари."))
                    Button { editing = .new } label: { Label(VL.text("Новый формат"), systemImage: "plus") }.buttonStyle(QuietButton(primary: true))
                }
                ForEach(NativeSummaryPresentationCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(category.title).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        if category == .builtIn {
                            Text(VL.text("Встроенные форматы доступны только для чтения. Создайте копию, чтобы изменить название и инструкцию.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
                        }
                        let choices = recipes.filter { $0.category == category }
                        if choices.isEmpty {
                            Text(VL.text("Пока нет своих форматов. Создайте новый или скопируйте встроенный.")).font(.system(size: 12)).foregroundColor(Ink.muted)
                        } else {
                            VStack(spacing: 1) { ForEach(choices) { recipe in recipeRow(recipe) } }.cornerRadius(9)
                        }
                    }
                }
                Text(VL.text("Изменения применяются к новым запросам. Ранее созданные саммари сохраняют исходную инструкцию и её версию.")).font(.system(size: 12)).foregroundColor(Ink.muted).lineSpacing(4)
                Text(VL.text("Сохранение формата не запускает обработку и не меняет выбранный формат. Выберите его при создании саммари или в настройках автоматической обработки.")).font(.system(size: 12)).foregroundColor(Ink.muted).lineSpacing(4)
                if let error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new: NativeFormatEditor(library: library, original: nil)
            case .edit(let format): NativeFormatEditor(library: library, original: format)
            case .duplicate(let recipe): NativeFormatEditor(library: library, original: nil, source: recipe)
            case .legacy(let template): NativeTemplateEditor(model: model, template: template)
            }
        }
        .confirmationDialog(VL.text("Удалить формат?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(VL.text("Удалить формат"), role: .destructive) {
                if let format = deleting, !format.isBuiltin {
                    do { try library.deleteFormat(format); error = nil }
                    catch { self.error = error.localizedDescription }
                }
                deleting = nil
            }
            Button(VL.text("Отмена"), role: .cancel) { deleting = nil }
        } message: {
            Text(VL.text("Формат будет удалён без возможности восстановления. Готовые саммари и уже созданные задания сохранятся."))
        }
        .onAppear { model.loadWorkspace() }
        .onChange(of: model.processingRoot ?? model.localAI?.root) { _ in
            editing = nil; deleting = nil; error = nil; model.loadWorkspace()
        }
        .onChange(of: ObjectIdentifier(library)) { _ in editing = nil; deleting = nil; error = nil }
    }
    private func recipeRow(_ recipe: NativeSummaryRecipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: recipe.category == .builtIn ? "text.justify" : "text.badge.plus").font(.system(size: 18)).frame(width: 40, height: 40).background(Ink.elevated).cornerRadius(8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(recipe.title).font(.system(size: 15, weight: .medium))
                    Text(recipe.detail).font(.system(size: 12)).foregroundColor(Ink.muted).lineLimit(2)
                }
                Spacer(minLength: 4)
                if !recipe.isReadOnly {
                    Button(VL.text("Редактировать")) {
                        if let template = recipe.template { editing = .legacy(template) }
                        else { editing = .edit(recipe.format) }
                    }.buttonStyle(QuietButton())
                }
                Menu {
                    Button(VL.text("Создать копию")) { editing = .duplicate(recipe) }
                    if recipe.template == nil && !recipe.format.isBuiltin {
                        Button(VL.text("Удалить формат"), role: .destructive) { deleting = recipe.format }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help(VL.text("Действия с форматом")).accessibilityLabel(VL.text("Действия с форматом") + " · " + recipe.title)
            }
            DisclosureGroup(VL.text("Инструкция для саммари")) {
                Text(recipe.displayInstructions).font(.system(size: 12)).foregroundColor(Ink.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.system(size: 12)).foregroundColor(Ink.secondary)
        }.padding(18).background(Ink.surface)
    }
}

struct NativeFormatEditor: View {
    @ObservedObject var library: NativeLibraryController
    let original: VectaSummaryInterpretation?
    var source: NativeSummaryRecipe? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var error: String?
    private var copying: Bool { source != nil || original?.isBuiltin == true }
    private var normalizedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedPrompt: String {
        prompt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var valid: Bool {
        VectaSummaryInterpretation(id: "detailed", title: normalizedTitle, prompt: normalizedPrompt, revision: 1).isValid
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(title: copying ? VL.text("Копия формата") : original == nil ? VL.text("Новый формат") : VL.text("Редактировать формат"))
            HStack { Text(VL.text("Название")); Spacer(); Text("\(normalizedTitle.count)/120").monospacedDigit() }.font(.system(size: 12)).foregroundColor(Ink.secondary)
            TextField(VL.text("Например, рабочая встреча"), text: $title).textFieldStyle(.plain).padding(12).background(Ink.elevated).cornerRadius(7)
            HStack { Text(VL.text("Инструкция для саммари")); Spacer(); Text("\(normalizedPrompt.count)/12 000").monospacedDigit() }.font(.system(size: 12)).foregroundColor(Ink.secondary)
            TextEditor(text: $prompt).accessibilityLabel(VL.text("Инструкция для саммари")).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).background(Ink.elevated).cornerRadius(7).frame(height: 220)
            Text(VL.text("Опишите, что выделить в записи и как оформить результат. Не просите модель дополнять неизвестные факты.")).font(.system(size: 12)).foregroundColor(Ink.muted)
            if !valid && (!title.isEmpty || !prompt.isEmpty) {
                Text(VL.text("Заполните название и инструкцию в пределах счётчиков. Название — до 512 байт UTF-8, инструкция — до 48 000; управляющие символы недопустимы, кроме переноса строки и табуляции в инструкции.")).font(.system(size: 12)).foregroundColor(Ink.error)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }
            HStack {
                Spacer()
                Button(VL.text("Отмена")) { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button(VL.text("Сохранить")) {
                    guard valid else { return }
                    do {
                        if let original, !copying { try library.updateFormat(original, title: normalizedTitle, prompt: normalizedPrompt) }
                        else { _ = try library.createFormat(title: normalizedTitle, prompt: normalizedPrompt) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(QuietButton(primary: true)).disabled(!valid)
            }
        }.padding(28).frame(width: 580).background(Ink.canvas).foregroundColor(Ink.text)
        .onAppear {
            title = source?.title ?? original?.title ?? ""
            prompt = source?.instructions ?? original?.prompt ?? ""
            if copying { title += VL.text(" — копия") }
        }
    }
}

/// Recording and queue read the same host-owned state, not independent view timers.
