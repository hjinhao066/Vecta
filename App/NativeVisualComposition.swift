import AppKit
import CoreText

/// Presentation only. Neither this document nor editorial selection mutates saved reports.
struct NativeVisualComposition {
    enum Family:String,CaseIterable {case hero,comparison,timeline,actions,metrics,balanced,causal}
    enum Role:String {
        case main,thought,decision,task,metric,comparison,quote,warning,context,outcome
        var title:String {
            switch self {
            case .main:return VL.text("Главный вывод")
            case .thought:return VL.text("Ключевая мысль")
            case .decision:return VL.text("Решение")
            case .task:return VL.text("Задача")
            case .metric:return VL.text("Показатель")
            case .comparison:return VL.text("Сравнение")
            case .quote:return VL.text("Цитата")
            case .warning:return VL.text("Предупреждение")
            case .context:return VL.text("Контекст")
            case .outcome:return VL.text("Итог")
            }
        }
    }
    struct Text {
        let text:String
        let frame:CGRect
        let size:CGFloat
        let bold:Bool
        var secondary:Bool=false
        var centered:Bool=false
    }
    struct Surface {
        enum Style {case inset,chip,quote}
        let frame:CGRect
        let style:Style
    }
    struct Symbol {let name:String;let frame:CGRect}
    struct Rule {let start:CGPoint;let end:CGPoint}
    struct Card {
        let id:String
        let role:Role
        let frame:CGRect
        let texts:[Text]
        let sourceSegments:[Int]
        let componentID:String
        var surfaces:[Surface]=[]
        var symbols:[Symbol]=[]
        var rules:[Rule]=[]
        var readableText:String {texts.map(\.text).joined(separator:"\n")}
    }
    static let size=CGSize(width:1200,height:840)
    let family:Family
    let heading:[Text]
    let cards:[Card]
    let footer:Text
    let omittedIDs:[String]
    let completeText:String
    var categoryFrame:CGRect? {heading.first.map {CGRect(x:$0.frame.minX-12,y:$0.frame.minY-5,width:min(1152,NativeVisualTypesetter.width($0.text,size:$0.size,bold:$0.bold)+24),height:$0.frame.height+10)}}
    var allText:[Text] {heading+cards.flatMap(\.texts)+[footer]}
    var readableText:String {(heading.map(\.text)+cards.map(\.readableText)+[footer.text]).joined(separator:"\n\n")}

    /// Includes all geometry and typography, not appearance or viewport size.
    var fingerprint:String {
        ([family.rawValue]+allText.map {"\($0.text)|\($0.frame)|\($0.size)|\($0.bold)|\($0.centered)"}
            + cards.map {"\($0.id)|\($0.role.rawValue)|\($0.frame)|\($0.surfaces.map {String(describing:$0.frame)}.joined())|\($0.symbols.map {$0.name+String(describing:$0.frame)}.joined())|\($0.rules.map {String(describing:$0.start)+String(describing:$0.end)}.joined())"}).joined(separator:"\n")
    }
}

/// One font/paragraph contract for measurement, on-screen drawing and PDF drawing.
enum NativeVisualTypesetter {
    static func attributed(_ text:String,size:CGFloat,bold:Bool,color:NSColor = .black,centered:Bool=false)->NSAttributedString {
        let paragraph=NSMutableParagraphStyle()
        paragraph.lineSpacing=3;paragraph.lineBreakMode = .byWordWrapping;paragraph.alignment=centered ? .center:.left
        return NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular),.paragraphStyle:paragraph,.foregroundColor:color])
    }
    static func width(_ text:String,size:CGFloat,bold:Bool)->CGFloat {
        ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text,size:size,bold:bold)),nil,nil,nil))
    }
    static func height(_ text:String,width:CGFloat,size:CGFloat,bold:Bool)->CGFloat {
        guard !text.isEmpty,width>0 else {return 0}
        let value=attributed(text,size:size,bold:bold)
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(value),CFRange(),nil,CGSize(width:width,height:.greatestFiniteMagnitude),nil).height)+3
    }
    static func fits(_ text:NativeVisualComposition.Text)->Bool {
        guard !text.text.isEmpty else {return true}
        let value=attributed(text.text,size:text.size,bold:text.bold,centered:text.centered)
        let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(),CGPath(rect:CGRect(origin:.zero,size:text.frame.size),transform:nil),nil)
        return CTFrameGetVisibleStringRange(frame).length==value.length
    }
}

enum NativeVisualComposer {
    private struct Candidate {
        let id:String
        let blockID:String
        let type:AIVisualBlockType
        let role:NativeVisualComposition.Role
        let title:String
        let body:String
        let value:String?
        let metadata:String
        let sources:[Int]
        let order:Int
        let symbol:String?
        let context:String
        let component:AIVisualComponentDescriptor
        var priority:Int {
            switch role {case .decision:return 110;case .task:return 105;case .warning:return 100;case .main,.outcome:return 95;case .metric:return 90;case .comparison:return 85;case .thought:return 65;case .quote:return 55;case .context:return 40}
        }
        var complete:String {[title,value,body,metadata].compactMap {$0}.filter {!$0.isEmpty}.joined(separator:"\n")}
    }
    private static func plain(_ text:String)->String {
        AIExportText.plain(text).split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
    }
    private static func role(_ type:AIVisualBlockType)->NativeVisualComposition.Role {
        switch type {
        case .hero:return .main
        case .keyPoints:return .thought
        case .decisions:return .decision
        case .tasks:return .task
        case .statistics,.chart:return .metric
        case .comparison,.decisionMatrix:return .comparison
        case .quotes:return .quote
        case .risks:return .warning
        case .takeaway:return .outcome
        default:return .context
        }
    }
    static func make(report:AIVisualSummary,speakers:AIRecordingSpeakers,formatTitle:String?=nil,semantic:AISemanticSummary?=nil)throws->NativeVisualComposition {
        try Task.checkCancellation()
        let report=AIVisualEditorial.refined(speakers.renderedVisual(report))
        let semanticEntries=semantic.map {speakers.renderedSemantic($0).deduplicatedEntries} ?? []
        let icons=AIVisualIconCatalog.allocate(report,supported:NativeVisualSymbolLibrary.supported)
        var candidates=[Candidate](),keys=Set<String>()
        for block in report.blocks {
            for (index,item) in block.items.enumerated() {
                let body=AIExportText.plain(speakers.render(item.tokens)).trimmingCharacters(in:.whitespacesAndNewlines),title=plain(item.title.isEmpty ? block.title:item.title)
                let value=item.value.map(plain).flatMap {$0.isEmpty ? nil:$0} ?? item.number.map {number in
                    let raw=String(number)
                    let numeric=raw.hasSuffix(".0") ? String(raw.dropLast(2)):raw
                    return numeric+(item.unit.map {" "+$0} ?? "")
                }
                let originalType=semanticEntries.first(where:{$0.item==item})?.kind.blockType ?? block.type
                let type=block.type == .hero && originalType == .keyPoints ? AIVisualBlockType.hero:originalType
                guard !body.isEmpty || value?.isEmpty == false else {continue}
                let metadata=[block.role.flatMap {label($0)},item.speakerID.map {speakers.name($0)},item.date,item.deadline,item.value == nil && item.number != nil ? nil:item.unit].compactMap {$0}.filter {!$0.isEmpty}.joined(separator:" · ")
                // Only literal duplicates with identical kinds/claims/attribution are merged.
                let key=[type.rawValue,type == .comparison ? block.id:"",title,body,value ?? "",item.number.map {String($0)} ?? "",item.unit ?? "",item.speakerID ?? "",metadata].joined(separator:"|")
                guard keys.insert(key).inserted else {continue}
                candidates.append(Candidate(id:block.id+"/"+String(index),blockID:type == .comparison ? (semanticEntries.first(where:{$0.item==item})?.id ?? block.id):block.id,type:type,role:role(type),title:title,body:body,value:value,metadata:metadata,sources:item.sourceSegments,order:candidates.count,symbol:icons[block.id+":item:"+String(index)] ?? icons[block.id],context:plain(block.title),component:AIVisualComponentRegistry.select(block,style:report.nativeStyle ?? .editorial,wide:true)))
            }
        }
        let title=plain(report.title)
        var heading=[NativeVisualComposition.Text]()
        let category=plain(formatTitle ?? report.category ?? VL.text("Обзор записи"))
        // A long valid title gets more header space, never an ellipsis.
        let titleSize:CGFloat=38
        let titleHeight=NativeVisualTypesetter.height(title,width:1128,size:titleSize,bold:true)
        let categoryHeight=NativeVisualTypesetter.height(category,width:1128,size:18,bold:true)
        let titleY=max(62,26+categoryHeight+10)
        heading.append(.init(text:category,frame:CGRect(x:36,y:26,width:1128,height:categoryHeight),size:18,bold:true,secondary:true))
        heading.append(.init(text:title,frame:CGRect(x:36,y:titleY,width:1128,height:titleHeight),size:titleSize,bold:true))
        var top=max(180,titleY+titleHeight+22)
        if let subtitle=report.subtitle.map(plain),!subtitle.isEmpty {
            let h=NativeVisualTypesetter.height(subtitle,width:1128,size:18,bold:false)
            // Subtitle is optional context, not a reason to consume the whole canvas.
            if h<=54 {heading.append(.init(text:subtitle,frame:CGRect(x:36,y:titleY+titleHeight+8,width:1128,height:h),size:18,bold:false,secondary:true));top=max(top,titleY+titleHeight+8+h+22)}
        }
        let area=CGRect(x:36,y:top,width:1128,height:max(0,778-top))
        let preferred=family(report,candidates)
        let ranked=candidates.filter {card($0,rect:area,featured:false) != nil}.sorted {$0.priority == $1.priority ? $0.order<$1.order:$0.priority>$1.priority}
        var best=[NativeVisualComposition.Card](),bestFamily=preferred,bestScore = -1
        let families=([preferred]+NativeVisualComposition.Family.allCases.filter {$0 != preferred}).filter {eligible($0,report:report,candidates:candidates)}
        for family in families {
            for count in stride(from:min(7,candidates.count),through:1,by:-1) {
                try Task.checkCancellation()
                let selected=selection(ranked,family:family,count:count)
                guard !selected.isEmpty else {continue}
                let selectedIDs=Set(selected.map(\.id))
                let comparisons=candidates.filter {$0.role == .comparison}
                let completeGroups=Dictionary(grouping:comparisons,by: \.blockID).values.allSatisfy {group in
                    let included=group.filter {selectedIDs.contains($0.id)}.count
                    return included==0 || included==group.count
                }
                guard completeGroups else {continue}
                let rectangles=slots(family,count:selected.count,area:area)
                var cards=[NativeVisualComposition.Card]()
                for (candidate,rect) in zip(selected,rectangles) {
                    guard let card=card(candidate,rect:rect,featured:family == .hero && cards.isEmpty) else {continue}
                    cards.append(card)
                }
                guard cards.count==selected.count else {continue}
                let score=selected.reduce(0) {$0+$1.priority*10}+(family == preferred ? 30:0)
                if score>bestScore {best=cards;bestFamily=family;bestScore=score}
            }
        }
        let displayed=Set(best.map(\.id)),omitted=candidates.filter {!displayed.contains($0.id)}.map(\.id)
        let importantOmissions=candidates.filter {omitted.contains($0.id) && [.decision,.task,.warning].contains($0.role)}.count
        let footerText=omitted.isEmpty ? "Vecta · "+VL.text("Обзор записи") : VL.text("Вне холста: \(omitted.count) · обязательств и рисков: \(importantOmissions) · полный текст в сохранённом отчёте")
        let footer=NativeVisualComposition.Text(text:footerText,frame:CGRect(x:36,y:800,width:1128,height:26),size:16,bold:false,secondary:true)
        if candidates.isEmpty || best.isEmpty {
            heading.append(.init(text:candidates.isEmpty ? VL.text("Нет сохранённых визуальных данных"):VL.text("Содержание не помещается без потери смысла. Откройте сохранённый отчёт."),frame:CGRect(x:64,y:350,width:1072,height:140),size:24,bold:false,secondary:true))
        }
        let document=NativeVisualComposition(family:bestFamily,heading:heading,cards:best,footer:footer,omittedIDs:omitted,completeText:([title,report.subtitle ?? ""]+report.blocks.map(\.title)+candidates.map(\.complete)+report.blocks.flatMap {($0.edges ?? []).map(\.label)}).filter {!$0.isEmpty}.joined(separator:"\n\n"))
        let bounds=CGRect(origin:.zero,size:NativeVisualComposition.size)
        guard document.allText.allSatisfy({bounds.contains($0.frame) && NativeVisualTypesetter.fits($0)}),
              document.cards.allSatisfy({card in heading.allSatisfy {!$0.frame.intersects(card.frame)} && !footer.frame.intersects(card.frame)}) else {throw AIProcessingError.invalidSummary}
        return document
    }
    private static func label(_ role:AIVisualRole)->String? {
        switch role {case .fact:return nil;case .position:return VL.text("Позиция участника");case .interpretation:return VL.text("Интерпретация модели");case .hypothesis:return VL.text("Гипотеза · требует проверки")}
    }
    private static func causal(_ report:AIVisualSummary)->Bool {
        // Require explicit labelled source links; three neighbouring cards are not causality.
        report.blocks.contains {block in
            guard block.type == .processFlow,block.items.count==3,let edges=block.edges else {return false}
            return edges.contains {$0.from==0 && $0.to==1 && ["причина","cause"].contains($0.label.lowercased()) && !$0.sourceSegments.isEmpty}
                && edges.contains {$0.from==1 && $0.to==2 && ["решение","solution"].contains($0.label.lowercased()) && !$0.sourceSegments.isEmpty}
        }
    }
    private static func family(_ report:AIVisualSummary,_ candidates:[Candidate])->NativeVisualComposition.Family {
        if causal(report) {return .causal}
        if candidates.filter({$0.role == .comparison}).count>=2 {return .comparison}
        if candidates.filter({$0.role == .decision || $0.role == .task}).count>=2 {return .actions}
        if candidates.filter({$0.role == .metric}).count>=2 {return .metrics}
        if candidates.filter({$0.type == .timeline || $0.type == .processFlow}).count>=2 {return .timeline}
        if candidates.contains(where:{$0.role == .main || $0.role == .outcome}) || candidates.count<=2 {return .hero}
        return .balanced
    }
    private static func eligible(_ family:NativeVisualComposition.Family,report:AIVisualSummary,candidates:[Candidate])->Bool {
        switch family {
        case .causal:return causal(report)
        case .comparison:return candidates.filter {$0.role == .comparison}.count>=2
        case .timeline:return candidates.filter {$0.type == .timeline || $0.type == .processFlow}.count>=2
        case .actions:return candidates.contains {$0.role == .decision || $0.role == .task}
        case .metrics:return candidates.contains {$0.role == .metric}
        case .hero,.balanced:return true
        }
    }
    private static func selection(_ ranked:[Candidate],family:NativeVisualComposition.Family,count:Int)->[Candidate] {
        let selected=Array(ranked.prefix(count))
        switch family {
        case .comparison:
            // A comparison is atomic: never present one side as the whole comparison.
            guard let group=ranked.first(where:{$0.role == .comparison})?.blockID else {return []}
            let pair=ranked.filter {$0.blockID==group}.sorted {$0.order<$1.order}
            if pair.count>=2 {
                guard count>=pair.count else {return []}
                return pair+ranked.filter {$0.blockID != group}.prefix(count-pair.count)
            }
            // Separate semantic comparison entries are complete claims, not invented sides.
            let comparisons=ranked.filter {$0.role == .comparison}.prefix(count)
            guard comparisons.count>=2 else {return []}
            return Array(comparisons)+ranked.filter {$0.role != .comparison}.prefix(count-comparisons.count)
        case .causal:
            let group=ranked.filter {$0.type == .processFlow}.sorted {$0.order<$1.order}
            guard group.count==3,count==3 else {return []}
            return group
        case .timeline:
            let events=ranked.filter {$0.type == .timeline || $0.type == .processFlow}.sorted {$0.order<$1.order}
            // Do not reorder events by salience or mix unrelated context into the sequence.
            guard count>=2,count<=events.count else {return []}
            return Array(events.prefix(count))
        case .hero:
            if let lead=selected.first(where:{$0.role == .main || $0.role == .outcome}) {return [lead]+selected.filter {$0.id != lead.id}}
            return selected
        case .actions:
            guard selected.contains(where:{$0.role == .decision || $0.role == .task}) else {return []}
            return selected.sorted {a,b in
                let first=a.role == .decision,second=b.role == .decision
                return first != second ? first:a.order<b.order
            }
        case .metrics:
            guard selected.contains(where:{$0.role == .metric}) else {return []}
            return selected.sorted {a,b in
                let first=a.role == .metric,second=b.role == .metric
                return first != second ? first:a.order<b.order
            }
        case .balanced:
            let ordered=selected.sorted {$0.order<$1.order}
            if ordered.count==5,let lead=ordered.first,let metric=ordered.dropFirst().first(where:{$0.role == .metric}) {
                return [lead,metric]+ordered.filter {$0.id != lead.id && $0.id != metric.id}
            }
            return ordered
        }
    }
    private static func slots(_ family:NativeVisualComposition.Family,count:Int,area:CGRect)->[CGRect] {
        let gap:CGFloat=16
        func grid(_ count:Int,_ area:CGRect,columns:Int)->[CGRect] {
            let rows=(count+columns-1)/columns,h=(area.height-gap*CGFloat(rows-1))/CGFloat(rows)
            return (0..<count).map {i in
                let row=i/columns,n=min(columns,count-row*columns),w=(area.width-gap*CGFloat(n-1))/CGFloat(n)
                return CGRect(x:area.minX+CGFloat(i%columns)*(w+gap),y:area.minY+CGFloat(row)*(h+gap),width:w,height:h)
            }
        }
        if count==1 {return [area]}
        if family == .causal {return grid(count,area,columns:3)}
        if family == .hero || family == .actions {
            if count==2 {let w=(area.width-gap)*0.62;return [CGRect(x:area.minX,y:area.minY,width:w,height:area.height),CGRect(x:area.minX+w+gap,y:area.minY,width:area.width-w-gap,height:area.height)]}
            if count==3 {
                let h=area.height*0.54,w=(area.width-gap)*0.64
                return [CGRect(x:area.minX,y:area.minY,width:w,height:h),
                        CGRect(x:area.minX+w+gap,y:area.minY,width:area.width-w-gap,height:h),
                        CGRect(x:area.minX,y:area.minY+h+gap,width:area.width,height:area.height-h-gap)]
            }
            let h=area.height*(count<=4 ? 0.52:0.44)
            let lead=CGRect(x:area.minX,y:area.minY,width:area.width,height:h)
            let rest=CGRect(x:area.minX,y:area.minY+h+gap,width:area.width,height:area.height-h-gap)
            return [lead]+grid(count-1,rest,columns:count<=4 ? count-1:3)
        }
        if family == .balanced,count==5 {
            let h=(area.height-gap)*0.53,w=(area.width-gap)*0.61
            return [CGRect(x:area.minX,y:area.minY,width:w,height:h),
                    CGRect(x:area.minX+w+gap,y:area.minY,width:area.width-w-gap,height:h)]
                + grid(3,CGRect(x:area.minX,y:area.minY+h+gap,width:area.width,height:area.height-h-gap),columns:3)
        }
        if family == .comparison,count>2 {
            let h=area.height*0.66
            return grid(2,CGRect(x:area.minX,y:area.minY,width:area.width,height:h),columns:2)+grid(count-2,CGRect(x:area.minX,y:area.minY+h+gap,width:area.width,height:area.height-h-gap),columns:min(3,count-2))
        }
        return grid(count,area,columns:family == .timeline ? min(3,count):(count==2 ? 2:count<=4 ? 2:3))
    }
    private static func card(_ candidate:Candidate,rect:CGRect,featured:Bool)->NativeVisualComposition.Card? {
        guard rect.width>=200,rect.height>=120 else {return nil}
        let inset:CGFloat=22,width=rect.width-inset*2
        var texts=[NativeVisualComposition.Text](),surfaces=[NativeVisualComposition.Surface](),symbols=[NativeVisualComposition.Symbol](),rules=[NativeVisualComposition.Rule]()
        var y=rect.minY+inset
        func add(_ text:String,size:CGFloat,bold:Bool,secondary:Bool=false,centered:Bool=false,x:CGFloat?=nil,w:CGFloat?=nil)->Bool {
            guard !text.isEmpty else {return true}
            let availableWidth=w ?? width,origin=x ?? rect.minX+inset
            let h=NativeVisualTypesetter.height(text,width:availableWidth,size:size,bold:bold)
            guard y+h<=rect.maxY-inset else {return false}
            texts.append(.init(text:text,frame:CGRect(x:origin,y:y,width:availableWidth,height:h),size:size,bold:bold,secondary:secondary,centered:centered));y+=h+10
            return true
        }
        let metric=candidate.role == .metric && candidate.value != nil
        let comparison=candidate.role == .comparison && candidate.value != nil && [.featured,.stack,.timeline].contains(candidate.component.variant)
        let flow=[AIVisualBlockType.timeline,.processFlow].contains(candidate.type)
        let kicker=flow ? String(candidate.order+1)+" · "+candidate.role.title:candidate.role.title
        let symbolSpace:CGFloat=candidate.symbol == nil ? 0:38
        if let name=candidate.symbol {
            symbols.append(.init(name:name,frame:CGRect(x:rect.minX+inset,y:y,width:26,height:26)))
            surfaces.append(.init(frame:CGRect(x:rect.minX+inset-4,y:y-4,width:34,height:34),style:.inset))
        }
        guard add(kicker,size:16,bold:true,secondary:true,x:rect.minX+inset+symbolSpace,w:width-symbolSpace) else {return nil}
        y=max(y,rect.minY+inset+38)
        let context=candidate.context != candidate.title && candidate.context.count<=70 ? candidate.context:""
        if !context.isEmpty && !featured {guard add(context,size:16,bold:true,secondary:true) else {return nil}}
        guard add(candidate.title,size:featured ? 29:22,bold:true,centered:metric) else {return nil}
        if let value=candidate.value,!value.isEmpty {
            let start=y
            if comparison {y+=14}
            guard add(value,size:metric ? (rect.width>500 ? 76:58):46,bold:true,centered:true) else {return nil}
            if comparison {surfaces.append(.init(frame:CGRect(x:rect.minX+inset,y:start,width:width,height:y-start+4),style:.inset));y+=16}
        }
        var body=candidate.body
        if body==candidate.title || body==candidate.value {body=""}
        let metadataHeight=candidate.metadata.isEmpty ? 0:NativeVisualTypesetter.height(candidate.metadata,width:width-20,size:17,bold:false)+24
        if !body.isEmpty {
            let quote=candidate.role == .quote && [.sourceRail,.stack].contains(candidate.component.variant),lead=candidate.role == .main
            let panel=quote || lead
            let bodyWidth=width-(panel ? 28:0),bodySize:CGFloat=featured ? 23:18
            let available=rect.maxY-inset-y-metadataHeight-(panel ? 28:0)
            if NativeVisualTypesetter.height(body,width:bodyWidth,size:bodySize,bold:false)>available {
                guard !quote,let short=shortened(body),NativeVisualTypesetter.height(short,width:bodyWidth,size:bodySize,bold:false)<=available else {return nil}
                body=short
            }
            let panelTop=y
            if panel {y+=14}
            guard add(quote ? "«"+body+"»":body,size:bodySize,bold:false,centered:metric,x:rect.minX+inset+(panel ? 14:0),w:bodyWidth) else {return nil}
            if panel {
                surfaces.append(.init(frame:CGRect(x:rect.minX+inset,y:panelTop,width:width,height:y-panelTop+4),style:quote ? .quote:.inset))
                if quote {rules.append(.init(start:CGPoint(x:rect.minX+inset+3,y:panelTop+8),end:CGPoint(x:rect.minX+inset+3,y:y-4)))}
                y+=14
            }
        }
        if !candidate.metadata.isEmpty {
            let top=y;y+=7
            guard add(candidate.metadata,size:17,bold:false,secondary:true,x:rect.minX+inset+10,w:width-20) else {return nil}
            surfaces.append(.init(frame:CGRect(x:rect.minX+inset,y:top,width:width,height:y-top),style:.chip))
        }
        if flow {rules.append(.init(start:CGPoint(x:rect.minX+inset,y:rect.maxY-13),end:CGPoint(x:rect.maxX-inset,y:rect.maxY-13)))}
        guard surfaces.allSatisfy({rect.contains($0.frame)}),symbols.allSatisfy({rect.contains($0.frame)}) else {return nil}
        return .init(id:candidate.id,role:candidate.role,frame:rect,texts:texts,sourceSegments:candidate.sources,componentID:candidate.component.id,surfaces:surfaces,symbols:symbols,rules:rules)
    }
    private static func shortened(_ text:String)->String? {
        // Semantic equivalence cannot be proved locally. Only remove a literal
        // repeated sentence, preserving every distinct sentence and its order.
        var sentences=[String]();let range=text.startIndex..<text.endIndex
        text.enumerateSubstrings(in:range,options:.bySentences) {part,_,_,_ in
            if let part {let value=part.trimmingCharacters(in:.whitespacesAndNewlines);if !sentences.contains(value) {sentences.append(value)}}
        }
        let result=sentences.joined(separator:" ")
        return !result.isEmpty && result.count<text.count-4 ? result:nil
    }
}
