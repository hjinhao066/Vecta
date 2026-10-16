import SwiftUI
import AppKit

@MainActor final class NativeLibraryQuestionState:ObservableObject {
    @Published var answer:AILibraryAnswer?
    @Published var sources:[AILibrarySource]=[]
    @Published var draft=""
    @Published var phase=""
    @Published var busy=false
    @Published var model:AISummaryModelID?
}
struct NativeLibraryAIResults:View {
    @ObservedObject var model:NativeMacModel
    @ObservedObject var question:NativeLibraryQuestionState
    init(model:NativeMacModel) {self.model=model;self.question=model.libraryQuestionState}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:8) {
                    Image(systemName:"sparkles").foregroundColor(Ink.secondary)
                    Text(VL.text("Ответ Vecta")).font(.system(size:14,weight:.semibold))
                    Spacer()
                    if let selected=model.libraryQuestionModel {Text(selected.selectionTitle).font(.system(size:11)).foregroundColor(Ink.muted)}
                    Button(action:model.clearLibraryQuestion) {Image(systemName:"xmark").frame(width:24,height:24)}.buttonStyle(.plain).help(VL.text("Очистить вопрос и ответ")).accessibilityLabel(VL.text("Очистить вопрос и ответ"))
                }
                if model.search.trimmingCharacters(in:.whitespacesAndNewlines) != model.librarySearchSession.submittedQuestion {Text(model.librarySearchSession.submittedQuestion).font(.system(size:12)).foregroundColor(Ink.secondary).textSelection(.enabled)}
                if let error=model.searchError {
                    VStack(alignment:.leading,spacing:12) {Text(error).foregroundColor(Ink.secondary);Button(VL.text("Повторить вопрос"),action:model.askLibraryQuestion).buttonStyle(QuietButton())}
                } else if let answer=model.libraryAnswer {
                    if answer.status=="insufficient_evidence" {Text(VL.text("В расшифровках не нашлось достаточно информации для ответа.")).foregroundColor(Ink.secondary)}
                    else {
                        ForEach(Array(answer.paragraphs.enumerated()),id:\.offset) {_,paragraph in
                            VStack(alignment:.leading,spacing:10) {
                                Text(paragraph.text).font(.system(size:15)).lineSpacing(5).textSelection(.enabled)
                                HStack(spacing:8) {ForEach(paragraph.sourceIDs,id:\.self) {id in
                                    if let source=model.libraryAnswerSources.first(where:{$0.id==id}) {
                                        Button {model.openLibrarySource(source)} label:{Text("["+id.dropFirst()+"]"+(source.start.map{" · "+clock($0)} ?? ""))}.buttonStyle(.plain).font(.system(size:11,weight:.medium)).foregroundColor(Ink.secondary).help(source.title)
                                    }
                                }}
                            }
                        }
                    }
                } else if model.libraryQuestionBusy {
                    HStack(spacing:10) {ProgressView().controlSize(.small);Text(model.libraryQuestionPhase).font(.system(size:12)).foregroundColor(Ink.secondary)}
                    if !model.libraryAnswerDraft.isEmpty {Text(model.libraryAnswerDraft).font(.system(size:15)).lineSpacing(5).textSelection(.enabled)}
                }
                if !model.libraryAnswerSources.isEmpty {
                    Divider().overlay(Ink.border)
                    Text(VL.text("Источники · ")+VectaUX.recordings(Set(model.libraryAnswerSources.map(\.recordingKey)).count)).font(.system(size:12,weight:.medium)).foregroundColor(Ink.secondary)
                    ForEach(model.libraryAnswerSources) {source in
                        Button {model.openLibrarySource(source)} label:{
                            VStack(alignment:.leading,spacing:8) {
                                HStack(alignment:.top,spacing:12) {
                                    Text("["+source.id.dropFirst()+"]").font(.system(size:11)).foregroundColor(Ink.muted)
                                    Text(source.title).font(.system(size:14,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                                    Spacer(minLength:8)
                                    Image(systemName:"arrow.up.right").font(.system(size:11)).foregroundColor(Ink.muted)
                                }
                                HStack(spacing:12) {Text(source.date.vectaFormatted(date:.abbreviated,time:.shortened));if let start=source.start {Text(clock(start))} else {Text(VL.text("Без таймкода"))}}.font(.system(size:11)).foregroundColor(Ink.muted)
                                Text(source.text).font(.system(size:12)).foregroundColor(Ink.secondary).lineLimit(4).multilineTextAlignment(.leading)
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Ink.surface).cornerRadius(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(VL.text("Открыть источник: ")+source.title)
                    }
                }
            }.padding(18).frame(maxWidth:760,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
                .background(LibrarySearchScrollMemory(model:model))
        }.background(Ink.surface.opacity(0.35)).cornerRadius(10)
    }
    private func clock(_ seconds:Double)->String {let s=max(0,Int(seconds));return String(format:"%d:%02d",s/60,s%60)}
}

private struct LibrarySearchScrollMemory:NSViewRepresentable {
    var model:NativeMacModel
    func makeCoordinator()->Coordinator {Coordinator(model:model)}
    func makeNSView(context:Context)->NSView {NSView()}
    func updateNSView(_ view:NSView,context:Context) {
        let coordinator=context.coordinator
        DispatchQueue.main.async {
            var parent:NSView?=view
            while let v=parent {
                if let scroll=v as? NSScrollView {coordinator.attach(scroll);return};parent=v.superview
            }
        }
    }
    @MainActor final class Coordinator {
        let model:NativeMacModel
        var observer:NSObjectProtocol?
        weak var scroll:NSScrollView?
        init(model:NativeMacModel){self.model=model}
        func attach(_ view:NSScrollView) {
            guard scroll !== view else {return};scroll=view
            view.contentView.postsBoundsChangedNotifications=true
            view.contentView.scroll(to:NSPoint(x:0,y:model.libraryQuestionScroll));view.reflectScrolledClipView(view.contentView)
            observer=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:view.contentView,queue:.main) {[weak self] _ in
                Task { @MainActor in guard let self,self.model.hasLibraryQuestion else {return};self.model.libraryQuestionScroll=Double(self.scroll?.contentView.bounds.origin.y ?? 0) }
            }
        }
        deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    }
}
