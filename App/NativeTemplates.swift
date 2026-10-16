import SwiftUI

@MainActor extension NativeMacModel {
    /// Presentation must not show a prior library's templates while a new workspace is loading or rejected.
    var currentSummaryTemplates: [AISummaryTemplate] {
        guard let root = (processingRoot ?? localAI?.root)?.standardizedFileURL,
              workspaceStateRoot?.standardizedFileURL == root else { return [] }
        return workspace.templates
    }
}

/// Compatibility editor for an existing legacy template. New and duplicated
/// formats use the revisioned format store instead of creating another template.
struct NativeTemplateEditor: View {
    @ObservedObject var model: NativeMacModel
    let template: AISummaryTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var openingRoot: URL?
    @State private var error: String?
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 120 &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.count <= 6000
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(title: VL.text("Редактировать формат"))
            Text(VL.text("Сохранённый шаблон совместимости: исходный идентификатор и история сохраняются.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            HStack { Text(VL.text("Название")); Spacer(); Text("\(title.count)/120").monospacedDigit() }.font(.system(size: 12)).foregroundColor(Ink.secondary)
            TextField(VL.text("Название"), text: $title).textFieldStyle(.plain).padding(12).background(Ink.elevated).cornerRadius(7)
            HStack { Text(VL.text("Инструкция для саммари")); Spacer(); Text("\(prompt.count)/6 000").monospacedDigit() }.font(.system(size: 12)).foregroundColor(Ink.secondary)
            TextEditor(text: $prompt).frame(height: 220).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).background(Ink.elevated).cornerRadius(7).accessibilityLabel(VL.text("Инструкция для саммари"))
            Text(VectaUX.templateValidation(title: title, prompt: prompt) ?? VL.text("Инструкция будет применяться только к новым саммари.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            if let error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }
            HStack {
                Spacer()
                Button(VL.text("Отмена")) { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button(VL.text("Сохранить"), action: save).buttonStyle(QuietButton(primary: true)).disabled(!valid)
            }
        }.padding(28).frame(width: 580).background(Ink.canvas).foregroundColor(Ink.text)
        .onAppear {
            openingRoot = (model.processingRoot ?? model.localAI?.root)?.standardizedFileURL
            title = template.title
            prompt = template.prompt
        }
    }
    private func save() {
        guard valid else { return }
        guard let openingRoot, openingRoot == (model.processingRoot ?? model.localAI?.root)?.standardizedFileURL else {
            error = VL.text("Библиотека изменилась. Закройте редактор и откройте формат снова.")
            return
        }
        model.loadWorkspace()
        guard model.workspace.templates.first(where: { $0.id == template.id }) == template else {
            error = VL.text("Формат изменён в другом окне. Закройте редактор и откройте его снова.")
            return
        }
        let value = AISummaryTemplate(id: template.id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        do { try value.validate() }
        catch { self.error = error.localizedDescription; return }
        if model.editWorkspace({ catalog in
            if let index = catalog.templates.firstIndex(where: { $0.id == template.id }) { catalog.templates[index] = value }
        }) { dismiss() }
        else { error = model.analysisMessage ?? VL.text("Не удалось сохранить формат.") }
    }
}
