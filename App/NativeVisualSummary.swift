import SwiftUI
import AppKit

struct NativeVisualPreparationInput:Equatable {
    let report:AIVisualSummary
    let semantic:AISemanticSummary?
    let speakers:AIRecordingSpeakers
    var formatTitle:String?=nil
}
struct NativePreparedVisualDocument {
    let displayed:AIVisualSummary
    let composition:NativeVisualComposition
}

/// Immutable bounded preparation; native text measurement never happens in body.
actor NativeVisualPreparation {
    static let shared=NativeVisualPreparation()
    private var recent:[(NativeVisualPreparationInput,NativePreparedVisualDocument)]=[]
    func prepare(_ input:NativeVisualPreparationInput) throws -> NativePreparedVisualDocument {
        try Task.checkCancellation()
        if let index=recent.firstIndex(where:{$0.0==input}) {
            let entry=recent.remove(at:index);recent.append(entry);return entry.1
        }
        let displayed=AIVisualEditorial.refined(input.speakers.renderedVisual(input.semantic?.visual(style:.editorial) ?? input.report))
        let composition=try NativeVisualComposer.make(report:displayed,speakers:input.speakers,formatTitle:input.formatTitle,semantic:input.semantic)
        let value=NativePreparedVisualDocument(displayed:displayed,composition:composition)
        try Task.checkCancellation()
        recent.append((input,value));recent=Array(recent.suffix(2))
        return value
    }
}

/// One logical canvas; viewport changes never reflow its text or cards.
struct NativeVisualSummaryView:View {
    @Environment(\.colorScheme) private var colorScheme
    let report:AIVisualSummary
    var semantic:AISemanticSummary?=nil
    var formatTitle:String?=nil
    let speakers:AIRecordingSpeakers
    let segments:[AISpeechSegment]
    var play:(AISpeechSegment)->Void
    @State private var prepared:NativePreparedVisualDocument?
    @State private var preparedInput:NativeVisualPreparationInput?
    @State private var preparation:Task<Void,Never>?
    @State private var generation=UUID()
    @State private var failure=false
    private var input:NativeVisualPreparationInput {.init(report:report,semantic:semantic,speakers:speakers,formatTitle:formatTitle)}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            if let prepared,preparedInput==input {
                NativeVisualCanvas(document:prepared.composition,dark:colorScheme == .dark)
                    .aspectRatio(1200.0/840.0,contentMode:.fit)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel(prepared.composition.readableText)
                // Complete saved content remains available without enlarging the infographic.
                DisclosureGroup(VL.text("Полное содержание визуального отчёта")) {
                    Text(prepared.composition.completeText).font(.system(size:14)).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                }.font(.system(size:12)).foregroundColor(Ink.secondary)
            } else {
                ZStack {
                    Color.clear
                    if failure {Text(VL.text("Не удалось подготовить сохранённый отчёт. Исходные данные не изменены."))}
                    else {ProgressView(VL.text("Подготавливаем сохранённый отчёт…"))}
                }.aspectRatio(1200.0/840.0,contentMode:.fit)
            }
        }.frame(maxWidth:1200,alignment:.leading)
        .onAppear(perform:prepare).onChange(of:input) {_ in prepare()}
        .onDisappear {preparation?.cancel()}
    }
    private func prepare() {
        preparation?.cancel();failure=false
        let expected=input,token=UUID()
        generation=token
        preparation=Task(priority:.utility) {
            do {
                let value=try await NativeVisualPreparation.shared.prepare(expected)
                guard !Task.isCancelled,generation==token else {return}
                prepared=value;preparedInput=expected
            } catch is CancellationError {} catch {if generation==token {failure=true}}
        }
    }
}

/// Development-only, synthetic gallery. Never reads or changes user recordings.
struct NativeVisualComponentGallery:View {
    @State private var family="all"
    @State private var longText=false
    @State private var empty=false
    @AppStorage("Vecta.visualStyle") private var selectedStyle="editorial"
    private let segments=[AISpeechSegment(id:0,start:0,end:5,speaker:nil,text:VL.text("Проверка стоит 30 000 ₽. Нужно проверить передачу файлов.")),AISpeechSegment(id:1,start:6,end:10,speaker:nil,text:VL.text("Полный запуск стоит 90 000 ₽. Решение принимается после проверки."))]
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:24) {
                Text(VL.text("Vecta · библиотека компонентов")).font(.title.bold())
                Text(VL.text("Синтетические данные. Фиксированный холст 1200 × 840.")).foregroundColor(Ink.secondary)
                HStack {
                    VectaSelectionButton(title:family == "all" ? VL.text("Все семейства"):family,label:VL.text("Семейство компонентов")) {
                        Button(VL.text("Все семейства")) {family="all"}
                        ForEach(AIVisualBlockType.allCases,id:\.self) {type in Button(type.rawValue) {family=type.rawValue}}
                    }
                    Toggle(VL.text("Длинный текст"),isOn:$longText)
                    Toggle(VL.text("Пустые данные"),isOn:$empty)
                    Button(VL.text("Экспорт образца PDF…")) {exportSample()}
                }
                Text("1200 × 840").font(.caption)
                ForEach(AIVisualBlockType.allCases.filter {family == "all" || $0.rawValue==family},id:\.self) {type in
                    Text(type.rawValue).font(.system(.caption,design:.monospaced))
                    NativeVisualSummaryView(report:report(type),speakers:.initial(segments),segments:segments,play:{_ in})
                }
            }.padding(24)
        }.background(Ink.canvas).foregroundColor(Ink.text)
    }
    private func exportSample() {
        let type=AIVisualBlockType(rawValue:family) ?? .keyPoints
        let panel=NSSavePanel();panel.allowedContentTypes=[.pdf];panel.nameFieldStringValue="Vecta-Component-Sample.pdf"
        guard panel.runModal() == .OK,let url=panel.url else {return}
        do {
            try NativeVisualPDF.write(report:report(type),title:VL.text("Vecta · синтетический образец"),date:nil,duration:10,speakers:.initial(segments),segments:segments,textSummary:longText ? String(repeating:VL.text("Полный текст синтетического материала. "),count:300):VL.text("Полный текст синтетического материала."),to:url)
        } catch {NSAlert(error:error).runModal()}
    }
    private func report(_ type:AIVisualBlockType)->AIVisualSummary {
        let metrics=[AIVisualBlockType.chart,.statistics,.comparison].contains(type)
        let items=segments.enumerated().map {index,segment in
            AIVisualItem(title:index==0 ? VL.text("Проверка"):VL.text("Полный запуск"),tokens:[AISummaryToken(text:longText ? String(repeating:segment.text+" ",count:30):segment.text,speakerID:nil)],sourceSegments:[segment.id],value:metrics ? (index==0 ? "30 000 ₽":"90 000 ₽"):nil,number:metrics ? (index==0 ? 30000:90000):nil,unit:metrics ? "RUB":nil)
        }
        let graph=[AIVisualBlockType.processFlow,.conceptMap].contains(type)
        let block=AIVisualBlock(id:type.rawValue,type:type,title:VL.text("Проверка перед публикацией"),items:items,layout:.wide,role:.fact,chartKind:type == .chart ? .horizontal:nil,edges:graph ? [AIVisualEdge(from:0,to:1,label:VL.text("После проверки"),sourceSegments:[1])]:nil)
        return AIVisualSummary(schemaVersion:1,title:VL.text("Пример"),theme:"editorial",blocks:empty ? []:[block],nativeStyle:AIVisualStyle(rawValue:selectedStyle) ?? .editorial)
    }
}
