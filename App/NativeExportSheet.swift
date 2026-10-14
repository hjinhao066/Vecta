import SwiftUI
struct NativeExportSheet:View {
    @ObservedObject var model:NativeMacModel
    @Environment(\.dismiss) private var dismiss
    @State private var content="summary"
    @State private var pdf=true
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(VL.text("Экспорт записи")).font(.system(size:22,weight:.semibold))
            Text(VL.text("Содержание")).font(.system(size:12)).foregroundColor(Ink.secondary)
            VectaSelectionButton(title:choices.first(where:{$0.0==content})?.1 ?? VL.text("Саммари"),label:VL.text("Содержание экспорта")) {
                ForEach(choices,id:\.0) {choice in
                    Button(choice.1) {content=choice.0}.disabled(!model.canExportDocument(kind(for: choice.0)))
                }
            }
            VectaSegmentedControl(label:VL.text("Формат файла"),choices:[VectaChoice(id:true,title:"PDF"),VectaChoice(id:false,title:VL.text("Текст · TXT"))],selection:$pdf)
            Text(VL.text("Экспортируются сохранённые результаты. PDF сохраняет композицию инфографики; генерация ИИ не запускается.")).font(.system(size:12)).foregroundColor(Ink.secondary)
            if !model.canExportDocument(selectedKind) {
                Text(VL.text("Выбранное содержимое ещё не сохранено. Дождитесь обработки или выберите другой результат.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            }
            HStack {
                Button(VL.text("Сохранить аудио…"),action:model.exportAudio).disabled(model.selection?.audioURL == nil)
                Spacer()
                Button(VL.text("Отмена")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(VL.text("Сохранить…")) {
                    let kind = selectedKind
                    let asPDF = pdf
                    guard let context = model.captureExportContext(), model.canExportDocument(kind, context: context) else { return }
                    dismiss(); DispatchQueue.main.async { model.exportDocument(kind: kind, pdf: asPDF, context: context) }
                }.buttonStyle(QuietButton(primary:true)).disabled(!model.canExportDocument(selectedKind))
            }
        }.padding(24).frame(width:480).background(Ink.canvas).foregroundColor(Ink.text)
            .onAppear {
                content = ["full", "summary", "visual", "transcript"].first { model.canExportDocument(kind(for: $0)) } ?? "summary"
            }
    }
    private var selectedKind: NativeMacModel.ExportDocument { kind(for: content) }
    private func kind(for content: String) -> NativeMacModel.ExportDocument {
        switch content { case "transcript": return .transcript; case "visual": return .visualSummary; case "full": return .fullReport; case "fullTranscript": return .fullReportWithTranscript; default: return .summary }
    }
    private var choices:[(String,String)] {
        [("summary",VL.text("Текстовое саммари")),("transcript",VL.text("Расшифровка")),("visual",VL.text("Инфографика")),
         ("full",VL.text("Саммари и инфографика")),("fullTranscript",VL.text("Полный отчёт с расшифровкой"))]
    }
}
