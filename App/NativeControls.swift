import SwiftUI

struct NativePreparedTextPart {
    let kind:AITextDocument.Kind
    let source:String
    let text:AttributedString
}

/// Retain one bounded document, not every growing revision of a model draft.
actor NativeStreamingFormatter {
    static let shared=NativeStreamingFormatter()
    private var previousText:String?
    private var previousParts:[NativePreparedTextPart]=[]
    func format(_ text:String) throws -> [NativePreparedTextPart] {
        try Task.checkCancellation()
        if previousText==text {return previousParts}
        var prepared=[NativePreparedTextPart]()
        for (index,part) in AITextDocument(text).parts.enumerated() {
            try Task.checkCancellation()
            let source=part.displayText
            if previousParts.indices.contains(index),previousParts[index].kind==part.kind,previousParts[index].source==source {
                prepared.append(previousParts[index])
            } else {
                let formatted=(try? AttributedString(markdown:source,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
                prepared.append(NativePreparedTextPart(kind:part.kind,source:source,text:formatted))
            }
        }
        try Task.checkCancellation()
        if text.utf8.count<=1_000_000 {previousText=text;previousParts=prepared}
        else {previousText=nil;previousParts=[]}
        return prepared
    }
}

/// Displays actual model fragments; formatting never runs in a view body.
struct NativeStreamingText:View {
    let text:String
    @State private var parts:[NativePreparedTextPart]=[]
    @State private var preparedText=""
    var body:some View {
        LazyVStack(alignment:.leading,spacing:12) {
            ForEach(Array(parts.enumerated()),id:\.offset) {_,part in
                Text(part.text)
                    .font(part.kind == .code || part.kind == .table ? .system(size:12,design:.monospaced):.system(size:part.kind == .heading ? 16:13,weight:part.kind == .heading ? .bold:.regular)).lineSpacing(5).textSelection(.enabled)
                    .padding(.leading,part.kind == .quote ? 14:0)
                    .padding(.top,part.kind == .heading ? 8:0)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
        .task(id:text,priority:.utility) {
            if !text.hasPrefix(preparedText) {parts=[];preparedText=""}
            do {
                let prepared=try await NativeStreamingFormatter.shared.format(text)
                try Task.checkCancellation()
                parts=prepared;preparedText=text
            } catch is CancellationError {} catch {}
        }
    }
}

struct VectaChoice<ID:Hashable>:Identifiable {
    let id:ID
    let title:String
    var help:String=""
    var enabled=true
}

/// Native buttons keep tab/space activation, with arrow navigation within a group.
/// ViewThatFits measures full labels before choosing a two-column arrangement.
struct VectaSegmentedControl<ID:Hashable>:View {
    let label:String
    let choices:[VectaChoice<ID>]
    @Binding var selection:ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused:ID?
    var body:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:4) {ForEach(choices) {button($0).fixedSize(horizontal:true,vertical:false)}}
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:4) {ForEach(choices) {button($0)}}
        }.padding(4).background(Ink.surface).cornerRadius(9)
        .accessibilityElement(children:.contain).accessibilityLabel(label)
        .onMoveCommand {direction in
            let enabled=choices.filter(\.enabled)
            guard let index=enabled.firstIndex(where:{$0.id == (focused ?? selection)}),!enabled.isEmpty else{return}
            let delta:Int
            switch direction {case .left,.up:delta = -1;case .right,.down:delta=1;default:return}
            let next=enabled[(index+delta+enabled.count)%enabled.count].id
            focused=next;choose(next)
        }
    }
    private func choose(_ id:ID) {withAnimation(reduceMotion ? nil:.easeOut(duration:0.12)) {selection=id}}
    private func button(_ choice:VectaChoice<ID>)->some View {
        Button {focused=choice.id;choose(choice.id)} label:{
            Text(choice.title).font(.system(size:12,weight:selection==choice.id ? .semibold:.medium))
                .multilineTextAlignment(.center).padding(.horizontal,11).padding(.vertical,8)
                .frame(maxWidth:.infinity).foregroundColor(selection==choice.id ? Ink.canvas:Ink.secondary)
                .background(selection==choice.id ? Ink.text:Color.clear).cornerRadius(6)
        }.buttonStyle(.plain).disabled(!choice.enabled).focused($focused,equals:choice.id)
        .help(choice.help).accessibilityLabel(choice.title)
        .accessibilityValue(selection==choice.id ? VL.text("Выбрано"):VL.text("Не выбрано"))
        .accessibilityAddTraits(selection==choice.id ? [.isSelected]:[])
    }
}

struct VectaSelectionButton<Content:View>:View {
    let title:String
    let label:String
    @ViewBuilder var content:()->Content
    var body:some View {
        Menu(content:content) {
            HStack(spacing:8) {Text(title).lineLimit(1).truncationMode(.middle);Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold))}
                .font(.system(size:12,weight:.medium)).padding(.horizontal,12).padding(.vertical,9)
                .foregroundColor(Ink.text).background(Ink.elevated).cornerRadius(7)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal:false,vertical:true)
            .accessibilityLabel(label).accessibilityValue(title).help(title)
    }
}

struct VectaHistoryMenu:View {
    let results:[AIProcessingResult]
    @Binding var selection:UUID?
    var select:(UUID)->Void
    var body:some View {
        let current=results.first(where:{$0.request.id==selection}) ?? results.first
        VectaSelectionButton(title:VL.text("История · ")+(current?.request.createdAt.vectaFormatted(date:.abbreviated,time:.shortened) ?? VL.text("Нет версий")),label:VL.text("История обработок")) {
            ForEach(results,id:\.request.id) {result in
                Button {selection=result.request.id;select(result.request.id)} label:{
                    Label(result.request.createdAt.vectaFormatted(date:.abbreviated,time:.shortened)+" · "+result.request.format.displayTitle+" · "+result.request.selectedSummaryModel.title+" · "+result.stage.title,systemImage:current?.request.id==result.request.id ? "checkmark":"clock")
                }
            }
        }
    }
}

struct NativeSummaryModelSegments:View {
    @ObservedObject var host:LocalAIHost
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            VectaSegmentedControl(label:VL.text("Модель саммари"),choices:AISummaryModelID.allCases.map {VectaChoice(id:$0,title:$0.title,help:$0.description+". "+$0.memoryRequirement,enabled:$0.compatible())},selection:Binding(get:{host.summaryModel},set:host.selectSummaryModel))
            if host.statuses[host.summaryModel.rawValue]?.state != .installed {
                Text(VL.text("Модель не установлена — скачайте её в разделе «Локальный ИИ»")).font(.system(size:11)).foregroundColor(Ink.secondary)
            }
        }
    }
}
