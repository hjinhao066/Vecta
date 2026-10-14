import SwiftUI
struct NativeTemplateSettings:View {
    @ObservedObject var model:NativeMacModel
    @State private var editing:AISummaryTemplate?
    @State private var deleting:AISummaryTemplate?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text(VL.text("Шаблоны")).font(.system(size:20,weight:.semibold));Spacer();Button(VL.text("Новый шаблон")) {editing=AISummaryTemplate(id:UUID().uuidString,title:"",prompt:"")}.buttonStyle(QuietButton(primary:true))}
            Text(VL.text("Сохранённые шаблоны остаются локально. Ранее созданные саммари и инструкции в истории не изменяются.")).font(.system(size:12)).foregroundColor(Ink.secondary)
            ForEach(model.workspace.templates) {template in
                HStack {VStack(alignment:.leading,spacing:6) {Text(template.displayTitle).fontWeight(.medium);Text(template.prompt).font(.system(size:12)).foregroundColor(Ink.muted).lineLimit(2)};Spacer();Button(VL.text("Изменить")) {editing=template}.buttonStyle(QuietButton());Button {deleting=template} label:{Image(systemName:"trash")}.buttonStyle(.plain).help(VL.text("Удалить шаблон"))}.padding(14).background(Ink.surface).cornerRadius(8)
            }
        }.sheet(item:$editing) {template in NativeTemplateEditor(model:model,template:template)}
        .confirmationDialog(VL.text("Удалить шаблон?"),isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}})) {
            Button(VL.text("Удалить"),role:.destructive) {if let id=deleting?.id {model.editWorkspace {$0.templates.removeAll {$0.id==id}}};deleting=nil}
            Button(VL.text("Отмена"),role:.cancel) {deleting=nil}
        } message:{Text(VL.text("Существующие саммари и сохранённые инструкции истории не изменятся."))}
    }
}
private struct NativeTemplateEditor:View {
    @ObservedObject var model:NativeMacModel
    let template:AISummaryTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var title=""
    @State private var prompt=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(VL.text("Шаблон саммари")).font(.system(size:22,weight:.semibold))
            Text(VL.text("Название")).font(.system(size:12)).foregroundColor(Ink.secondary)
            TextField(VL.text("Название"),text:$title).textFieldStyle(.roundedBorder)
            Text(VL.text("Инструкция по структуре")).font(.system(size:12)).foregroundColor(Ink.secondary)
            TextEditor(text:$prompt).frame(height:180).font(.system(size:13)).accessibilityLabel(VL.text("Инструкция шаблона"))
            Text(VectaUX.templateValidation(title:title,prompt:prompt) ?? VL.text("Инструкция будет применяться только к новым саммари.")).font(.system(size:12)).foregroundColor(Ink.secondary)
            HStack {Spacer();Button(VL.text("Отмена")) {dismiss()}.keyboardShortcut(.cancelAction);Button(VL.text("Сохранить")) {
                let value=AISummaryTemplate(id:template.id,title:title.trimmingCharacters(in:.whitespacesAndNewlines),prompt:prompt.trimmingCharacters(in:.whitespacesAndNewlines))
                guard (try? value.validate()) != nil else{return}
                if model.editWorkspace({catalog in if let index=catalog.templates.firstIndex(where:{$0.id==value.id}) {catalog.templates[index]=value} else {catalog.templates.append(value)}}) {dismiss()}
            }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || title.count>120 || prompt.count>6000)}
        }.padding(24).frame(width:520).onAppear {title=template.displayTitle;prompt=template.prompt}
    }
}
