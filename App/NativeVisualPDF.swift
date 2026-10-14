import AppKit
import CoreText

/// A4 report with selectable CoreText content. Cards are split at text-line
/// boundaries instead of rasterizing a SwiftUI view or clipping long items.
enum NativeVisualPDF {
    static func write(report:AIVisualSummary,title:String,date:Date?,duration:Double?,speakers:AIRecordingSpeakers,segments:[AISpeechSegment],textSummary:String?=nil,fullTextDocument:AIFullTextSummary?=nil,transcript:String?=nil,to url:URL)throws {
        let report=AIVisualEditorial.refined(speakers.renderedVisual(report))
        let title=speakers.resolveText(title)
        let textSummary=textSummary.map(speakers.resolveText)
        let fullTextDocument=fullTextDocument.map(speakers.renderedFullText)
        let data=NSMutableData();var page=CGRect(x:0,y:0,width:595,height:842)
        guard let consumer=CGDataConsumer(data:data as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&page,[kCGPDFContextTitle:title,kCGPDFContextCreator:"Vecta"] as CFDictionary) else {throw AIProcessingError.invalidSummary}
        var y:CGFloat=46,pageNumber=0
        let width:CGFloat=503,bottom:CGFloat=780
        let textColor=NSColor(srgbRed:0.075,green:0.090,blue:0.115,alpha:1)
        let muted=NSColor(srgbRed:0.31,green:0.35,blue:0.40,alpha:1)
        var visualScale:CGFloat=1
        func attributed(_ text:String,size:CGFloat,weight:NSFont.Weight = .regular,color:NSColor?=nil)->NSAttributedString {
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=report.nativeStyle == .presentation ? 5:3;paragraph.paragraphSpacing=5
            return NSAttributedString(string:text,attributes:[.font:(NSFont(name:weight == .regular ? "ArialMT":"Arial-BoldMT",size:size*visualScale) ?? NSFont.systemFont(ofSize:size*visualScale,weight:weight)),.foregroundColor:color ?? textColor,.paragraphStyle:paragraph])
        }
        func draw(_ value:NSAttributedString,rect:CGRect)->Int {
            let setter=CTFramesetterCreateWithAttributedString(value)
            let path=CGPath(rect:CGRect(x:rect.minX,y:842-rect.maxY,width:rect.width,height:rect.height),transform:nil)
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil)
            context.textMatrix = .identity;CTFrameDraw(frame,context)
            return CTFrameGetVisibleStringRange(frame).length
        }
        func newPage() {
            if pageNumber>0 {context.endPDFPage()}
            context.beginPDFPage(nil);pageNumber+=1;y=46
            context.setFillColor(NSColor.white.cgColor);context.fill(page)
            _=draw(attributed(VL.text("Vecta · локальный аналитический отчёт"),size:9,color:muted),rect:CGRect(x:46,y:810,width:420,height:18))
            _=draw(attributed(String(pageNumber),size:9,color:muted),rect:CGRect(x:530,y:810,width:30,height:18))
        }
        func text(_ value:NSAttributedString,card:Bool=false,spacing:CGFloat=12)throws {
            var offset=0
            while offset<value.length {
                if bottom-y<64 {newPage()}
                let rest=value.attributedSubstring(from:NSRange(location:offset,length:value.length-offset))
                let inset:CGFloat=card ? 14:0
                let setter=CTFramesetterCreateWithAttributedString(rest)
                let needed=ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:0),nil,CGSize(width:width-inset*2,height:.greatestFiniteMagnitude),nil).height)+4
                let height=min(needed,bottom-y-inset*2)
                let rectangle=CGRect(x:46,y:y,width:width,height:height+inset*2)
                if card {
                    context.setFillColor(NSColor(srgbRed:1,green:1,blue:1,alpha:0.78).cgColor)
                    context.addPath(CGPath(roundedRect:CGRect(x:rectangle.minX,y:842-rectangle.maxY,width:rectangle.width,height:rectangle.height),cornerWidth:8,cornerHeight:8,transform:nil));context.fillPath()
                }
                let count=draw(rest,rect:CGRect(x:46+inset,y:y+inset,width:width-inset*2,height:height))
                guard count>0 else {throw AIProcessingError.invalidSummary}
                offset+=count;y+=height+inset*2+spacing
                if offset<value.length {newPage()}
            }
        }
        newPage()
        // The semantic report title leads the page; the recording name is
        // metadata, not a competing display heading.
        let mediumScale:CGFloat=503/892
        let category=attributed(report.category ?? VL.text("Обзор записи"),size:11*mediumScale,weight:.semibold,color:muted)
        let badgeSize=CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(category),CFRange(),nil,CGSize(width:width-40,height:40),nil)
        let badge=CGRect(x:46,y:y,width:ceil(badgeSize.width)+24*mediumScale,height:26*mediumScale)
        context.setFillColor(NSColor(srgbRed:0.905,green:0.935,blue:0.985,alpha:1).cgColor)
        context.addPath(CGPath(roundedRect:CGRect(x:badge.minX,y:842-badge.maxY,width:badge.width,height:badge.height),cornerWidth:badge.height/2,cornerHeight:badge.height/2,transform:nil));context.fillPath()
        _=draw(category,rect:CGRect(x:badge.minX+12*mediumScale,y:y+4*mediumScale,width:badge.width-24*mediumScale,height:badge.height))
        _=draw(attributed("Vecta",size:11*mediumScale,color:muted),rect:CGRect(x:520,y:y+4*mediumScale,width:29,height:badge.height))
        y+=badge.height+10*mediumScale
        try text(attributed(report.title,size:28*mediumScale,weight:.semibold),spacing:6)
        if report.title != title {try text(attributed(title,size:11*mediumScale,color:muted),spacing:4)}
        var metadata=[String]()
        if let date {metadata.append(date.vectaFormatted(date:.long,time:.shortened))}
        if let duration,duration.isFinite,duration>0 {metadata.append(String(format:VL.text("Длительность: %d:%02d"),Int(duration)/60,Int(duration)%60))}
        if !metadata.isEmpty {try text(attributed(metadata.joined(separator:" · "),size:11*mediumScale,color:muted),spacing:4)}
        if let subtitle=report.subtitle,!subtitle.isEmpty {try text(attributed(subtitle,size:14*mediumScale,color:muted),spacing:10)}
        func content(_ block:AIVisualBlock)->NSAttributedString {
            let value=NSMutableAttributedString(string:"")
            if ![AIVisualBlockType.chart,.processFlow,.conceptMap].contains(block.type) && !(block.type == .hero && block.title == report.title) {value.append(attributed(block.title+"\n",size:block.type == .hero ? 20:15,weight:.semibold))}
            if let role=block.role,role != .fact {
                let label=role == .position ? VL.text("Позиция участника"):role == .interpretation ? VL.text("Интерпретация модели"):VL.text("Гипотеза · требует проверки")
                value.append(attributed(label+"\n",size:9,color:muted))
            }
            let diagram=[AIVisualBlockType.chart,.processFlow,.conceptMap].contains(block.type)
            for (index,item) in block.items.enumerated() {
                if let metric=item.value,block.type != .chart {value.append(attributed(metric+"\n",size:22,weight:.semibold))}
                if !diagram && !item.title.isEmpty && !(block.items.count == 1 && item.title == block.title) {value.append(attributed((block.type == .timeline ? "\(index+1). ":"")+item.title+"\n",size:11,weight:.semibold))}
                let body=speakers.render(item.tokens)
                if !diagram || AIVisualEditorial.caption(body,title:item.title) != nil {value.append(attributed((block.type == .quotes ? "«"+body+"»":body)+"\n",size:block.type == .hero ? 12.5:10.5))}
                if let id=item.speakerID {value.append(attributed(speakers.name(id)+"\n",size:9,color:muted))}
                for date in [item.date,item.deadline].compactMap({$0}) {value.append(attributed(date+"\n",size:9,color:muted))}
            }
            for edge in block.edges ?? [] where block.items.indices.contains(edge.from) && block.items.indices.contains(edge.to) {
                // The painter already prints short labels; retain only its truncated tail here.
                if edge.label.count>30 {value.append(attributed(edge.label+"\n",size:9,color:muted))}
            }
            return value
        }
        func measured(_ value:NSAttributedString,width:CGFloat)->CGFloat {
            ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(value),CFRange(location:0,length:0),nil,CGSize(width:width,height:.greatestFiniteMagnitude),nil).height)+6
        }
        func background(_ block:AIVisualBlock,_ rect:CGRect) {
            if report.nativeStyle == .minimal {return}
            let c=AIVisualEditorialPalette.color(report.blocks.firstIndex {$0.id == block.id} ?? 0,
                psychological:report.category?.lowercased().contains("психолог") == true)
            let tint=NSColor(srgbRed:c.red,green:c.green,blue:c.blue,alpha:1)
            context.setFillColor(tint.cgColor)
            context.addPath(CGPath(roundedRect:CGRect(x:rect.minX,y:842-rect.maxY,width:rect.width,height:rect.height),cornerWidth:8,cornerHeight:8,transform:nil));context.fillPath()
        }
        func metricItems(_ block:AIVisualBlock)->[NSAttributedString] {
            block.items.map {item in
                let v=NSMutableAttributedString(string:"")
                if let amount=item.value {v.append(attributed(amount+"\n",size:18,weight:.semibold))}
                v.append(attributed(item.title+"\n",size:10,weight:.semibold))
                v.append(attributed(speakers.render(item.tokens)+"\n",size:10))
                return v
            }
        }
        func heroParts(_ block:AIVisualBlock)->(NSAttributedString,NSAttributedString)? {
            guard block.type == .hero,block.items.count==1 else {return nil}
            let value=content(block),body=speakers.render(block.items[0].tokens)
            let range=(value.string as NSString).range(of:body,options:.backwards)
            guard range.location != NSNotFound else {return nil}
            return (value.attributedSubstring(from:NSRange(location:0,length:range.location)),value.attributedSubstring(from:NSRange(location:range.location,length:value.length-range.location)))
        }
        func cardHeight(_ block:AIVisualBlock,width:CGFloat)->CGFloat {
            if let (heading,body)=heroParts(block) {return measured(heading,width:width-28)+measured(body,width:width-52)+52}
            if ([AIVisualBlockType.comparison,.statistics].contains(block.type) || (report.nativeStyle == .dashboard && block.items.count==2)),block.items.count==2,width>=225 {
                let w=(width-36)/2
                return measured(attributed(block.title,size:15,weight:.semibold),width:width-28)+28+(metricItems(block).map {measured($0,width:w)}.max() ?? 0)
            }
            return measured(content(block),width:width-28)+28
        }
        func drawCard(_ block:AIVisualBlock,rect:CGRect)throws {
            background(block,rect)
            if let (heading,body)=heroParts(block) {
                let h=measured(heading,width:rect.width-28)
                let inset=CGRect(x:rect.minX+14,y:rect.minY+14+h,width:rect.width-28,height:rect.height-h-28)
                context.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
                context.addPath(CGPath(roundedRect:CGRect(x:inset.minX,y:842-inset.maxY,width:inset.width,height:inset.height),cornerWidth:5,cornerHeight:5,transform:nil));context.fillPath()
                guard draw(heading,rect:CGRect(x:rect.minX+14,y:rect.minY+14,width:rect.width-28,height:h))==heading.length,
                      draw(body,rect:inset.insetBy(dx:12,dy:12))==body.length else {throw AIProcessingError.invalidSummary}
                return
            }
            if ([AIVisualBlockType.comparison,.statistics].contains(block.type) || (report.nativeStyle == .dashboard && block.items.count==2)),block.items.count==2,rect.width>=225 {
                let title=attributed(block.title,size:15,weight:.semibold),h=measured(title,width:rect.width-28)
                guard draw(title,rect:CGRect(x:rect.minX+14,y:rect.minY+14,width:rect.width-28,height:h))==title.length else {throw AIProcessingError.invalidSummary}
                let w=(rect.width-36)/2
                for (i,value) in metricItems(block).enumerated() {
                    guard draw(value,rect:CGRect(x:rect.minX+14+CGFloat(i)*(w+8),y:rect.minY+14+h,width:w,height:rect.height-h-28))==value.length else {throw AIProcessingError.invalidSummary}
                }
            } else {
                let value=content(block);guard draw(value,rect:rect.insetBy(dx:14,dy:14))==value.length else {throw AIProcessingError.invalidSummary}
            }
        }
        // Lay out at the medium-window content width, then scale the entire
        // vector card uniformly. A4 must not choose a different narrow topology.
        let logicalWidth:CGFloat=892,cardScale=width/logicalWidth,logicalGap:CGFloat=14
        let reportRows=AIVisualLayoutPlan.rows(report,wide:report.nativeStyle != .minimal && report.nativeStyle != .presentation)
        for row in reportRows {
            let logicalWidths=row.map {(logicalWidth-logicalGap*CGFloat(row.count-1))*CGFloat(AIVisualLayoutPlan.share($0,in:row))}
            let vectorHeights=zip(row,logicalWidths).map {NativeVisualPDFCardPainter.height($0.0,width:$0.1,speakers:speakers,style:report.nativeStyle ?? .editorial)}
            if let logicalHeight=vectorHeights.max(),logicalHeight*cardScale<bottom-46 {
                if y+logicalHeight*cardScale>bottom {newPage()}
                var x:CGFloat=46
                for (index,block) in row.enumerated() {
                    context.saveGState()
                    context.translateBy(x:x,y:842-y);context.scaleBy(x:cardScale,y:-cardScale)
                    try NativeVisualPDFCardPainter.draw(block,in:CGRect(x:0,y:0,width:logicalWidths[index],height:logicalHeight),context:context,speakers:speakers,style:report.nativeStyle ?? .editorial,report:report)
                    context.restoreGState()
                    x+=(logicalWidths[index]+logicalGap)*cardScale
                }
                y+=logicalHeight*cardScale+10
                continue
            }
            let heights=row.map {cardHeight($0,width:(width-12)*AIVisualLayoutPlan.share($0,in:row))}
            let diagram=row.contains { [.chart,.processFlow,.conceptMap].contains($0.type) }
            if row.count==2,!diagram,let h=heights.max(),h<bottom-46 {
                if y+h>bottom {newPage()}
                for (i,block) in row.enumerated() {
                    let cellWidth=(width-12)*AIVisualLayoutPlan.share(block,in:row)
                    let origin=i==0 ? 46:46+(width-12)*AIVisualLayoutPlan.share(row[0],in:row)+12
                    let rect=CGRect(x:origin,y:y,width:cellWidth,height:h)
                    try drawCard(block,rect:rect)
                }
                y+=h+12
            } else {
                for block in row {
                    if diagram {
                        let h=NativeVisualDiagramPainter.height(block,compact:false)
                        if y+h+50>bottom {newPage()}
                        try text(attributed(block.title,size:17,weight:.semibold))
                        let rect=CGRect(x:46,y:y,width:width,height:h+20)
                        background(block,rect)
                        context.saveGState();context.translateBy(x:0,y:842);context.scaleBy(x:1,y:-1)
                        NativeVisualDiagramPainter.draw(block,in:rect.insetBy(dx:14,dy:10),context:context,printing:true,compact:false)
                        context.restoreGState();y+=h+32
                    }
                    // The caption retains every item, source, and quote as real text.
                    // Exceptionally long cards split only at CoreText line boundaries.
                    let height=cardHeight(block,width:width)
                    if !diagram && height<bottom-46 {
                        if y+height>bottom {newPage()}
                        try drawCard(block,rect:CGRect(x:46,y:y,width:width,height:height));y+=height+12
                    } else {try text(content(block),card:block.type != .hero && !diagram)}
                }
            }
        }
        visualScale=1
        func appendixParagraph(_ raw:String)throws {
            for part in AITextDocument(raw).parts {
                if part.kind == .heading,bottom-y<95 {newPage()}
                let plain=AIExportText.plain(part.displayText)
                let rendered=(try? AttributedString(markdown:plain,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))).map {String($0.characters)} ?? plain
                try text(attributed(rendered,size:part.kind == .heading ? 14:11,weight:part.kind == .heading ? .semibold:.regular),spacing:part.kind == .heading ? 6:12)
            }
        }
        if fullTextDocument != nil || (textSummary?.isEmpty == false) {
            // Continue with the saved analysis itself, without an extra section label.
            // Card spacing plus 8pt gives roughly one to two lines.
            if bottom-y<95 {newPage()} else {y+=8}
            if let fullTextDocument {
                for paragraph in fullTextDocument.paragraphs {
                    if let heading=paragraph.heading,!heading.isEmpty {
                        if bottom-y<95 {newPage()}
                        try text(attributed(AIExportText.plain(heading),size:14,weight:.semibold),spacing:6)
                    }
                    try appendixParagraph(speakers.render(paragraph.tokens))
                }
            } else {
                for paragraph in (textSummary ?? "").components(separatedBy:"\n\n") where !paragraph.isEmpty {
                    try appendixParagraph(paragraph)
                }
            }
        }
        if let transcript,!transcript.isEmpty {if bottom-y<180 {newPage()} else {y+=20};try text(attributed(VL.text("Расшифровка"),size:22,weight:.semibold));try text(attributed(transcript,size:11))}
        context.endPDFPage();context.closePDF();try (data as Data).write(to:url,options:.atomic)
    }
}

/// Medium-window card geometry in logical points; the PDF applies one CTM scale.
enum NativeVisualPDFCardPainter {
    struct Element {var text:String;var size:CGFloat;var bold:Bool=false;var inset:CGFloat=0;var panel:Bool=false;var icon:String?=nil}
    static func symbol(_ type:AIVisualBlockType)->String {
        switch type {case .hero:return "sparkles";case .keyPoints:return "list.bullet";case .timeline:return "clock";case .decisions:return "checkmark.circle";case .tasks:return "checklist";case .comparison:return "rectangle.split.2x1";case .risks:return "exclamationmark.triangle";case .openQuestions:return "questionmark.circle";case .quotes:return "quote.opening";case .statistics,.chart:return "chart.bar";case .processFlow:return "arrow.right";case .conceptMap:return "point.3.connected.trianglepath.dotted";case .decisionMatrix:return "tablecells";case .takeaway:return "checkmark.seal"}
    }
    static func verdict(_ block:AIVisualBlock,style:AIVisualStyle)->Bool {AIVisualComponentRegistry.select(block,style:style,wide:false).variant == .verdict}
    static func diagram(_ block:AIVisualBlock)->Bool {[.chart,.processFlow,.conceptMap].contains(block.type)}
    static func elements(_ block:AIVisualBlock,speakers:AIRecordingSpeakers,style:AIVisualStyle)->[Element] {
        let centered=verdict(block,style:style),hero=block.type == .hero
        let lower=block.title.lowercased()
        let mark=lower.contains("сегмент") ? "square.grid.2x2":lower.contains("голос") ? "waveform":symbol(block.type)
        var result=[Element(text:block.title,size:hero || centered ? 22:17,bold:true,inset:centered ? 0:28,icon:centered ? nil:mark)]
        if centered {result.insert(.init(text:block.type == .decisions ? VL.text("РЕШЕНИЕ"):block.type == .openQuestions ? VL.text("ОТКРЫТЫЙ ВОПРОС"):VL.text("ГЛАВНЫЙ ВЫВОД"),size:10),at:0)}
        if let role=block.role,role != .fact {result.append(.init(text:role == .position ? VL.text("Позиция участника"):role == .interpretation ? VL.text("Интерпретация модели"):VL.text("Гипотеза · требует проверки"),size:10))}
        for (index,item) in block.items.enumerated() {
            if let value=item.value,block.type != .chart {result.append(.init(text:value,size:34,bold:true))}
            if !item.title.isEmpty && !(block.items.count==1 && item.title==block.title) {result.append(.init(text:([.tasks,.timeline].contains(block.type) ? "\(index+1). ":"")+item.title,size:13,bold:true))}
            let body=speakers.render(item.tokens)
            if hero && index==0 {
                let narrative=AIVisualEditorial.narrative(body)
                result.append(.init(text:narrative.main,size:13.5,panel:true))
                if let detail=narrative.detail {result.append(.init(text:detail,size:13.5,inset:28,icon:"text.bubble"))}
            } else if !diagram(block) || AIVisualEditorial.caption(body,title:item.title) != nil {
                result.append(.init(text:block.type == .quotes ? "«"+body+"»":body,size:centered ? 12.5:13))
            }
            let metadata=[item.speakerID.map(speakers.name),item.date,item.deadline].compactMap {$0}.joined(separator:" · ")
            if !metadata.isEmpty {result.append(.init(text:metadata,size:11))}
        }
        for edge in block.edges ?? [] where edge.label.count>30 {result.append(.init(text:edge.label,size:11))}
        return result.filter {!$0.text.isEmpty}
    }
    static func attributed(_ element:Element,centered:Bool)->NSAttributedString {
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=3;paragraph.alignment=centered ? .center:.left
        return NSAttributedString(string:element.text,attributes:[.font:NSFont.systemFont(ofSize:element.size,weight:element.bold ? .bold:.regular),.foregroundColor:NSColor(srgbRed:0.075,green:0.09,blue:0.115,alpha:1),.paragraphStyle:paragraph])
    }
    static func measured(_ element:Element,width:CGFloat,centered:Bool)->CGFloat {
        ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(attributed(element,centered:centered)),CFRange(),nil,CGSize(width:width-element.inset-(element.panel ? 24:0),height:.greatestFiniteMagnitude),nil).height)+4+(element.panel ? 24:0)
    }
    static func height(_ block:AIVisualBlock,width:CGFloat,speakers:AIRecordingSpeakers,style:AIVisualStyle)->CGFloat {
        let list=elements(block,speakers:speakers,style:style),centered=verdict(block,style:style)
        return 36+(centered ? 44:0)+list.reduce(0) {$0+measured($1,width:width-36,centered:centered)+10}+(diagram(block) ? NativeVisualDiagramPainter.height(block,compact:false)+10:0)
    }
    static func draw(_ block:AIVisualBlock,in rect:CGRect,context:CGContext,speakers:AIRecordingSpeakers,style:AIVisualStyle,report:AIVisualSummary)throws {
        let centered=verdict(block,style:style)
        let c=AIVisualEditorialPalette.color(report.blocks.firstIndex {$0.id == block.id} ?? 0,
            psychological:report.category?.lowercased().contains("психолог") == true)
        let tint=NSColor(srgbRed:c.red,green:c.green,blue:c.blue,alpha:1)
        let supported=Set(AIVisualIconCatalog.symbols.filter {NSImage(systemSymbolName:$0,accessibilityDescription:nil) != nil})
        let icons=AIVisualIconCatalog.allocate(report,supported:supported)
        let blockIcon=icons[block.id] ?? symbol(block.type)
        func fill(_ rectangle:CGRect,color:NSColor,radius:CGFloat=6) {context.setFillColor(color.cgColor);context.addPath(CGPath(roundedRect:rectangle,cornerWidth:radius,cornerHeight:radius,transform:nil));context.fillPath()}
        if style != .minimal {fill(rect,color:tint)}
        func icon(_ name:String,_ rectangle:CGRect) {NativeVisualPDFSymbol.draw(name,in:rectangle,context:context)}
        var y:CGFloat=centered ? max(18,(rect.height-height(block,width:rect.width,speakers:speakers,style:style))/2+18):18
        if centered {icon(blockIcon,CGRect(x:rect.midX-13,y:y,width:26,height:26));y+=44}
        let list=elements(block,speakers:speakers,style:style)
        for (index,element) in list.enumerated() {
            let h=measured(element,width:rect.width-36,centered:centered)
            if element.panel {fill(CGRect(x:18,y:y,width:rect.width-36,height:h),color:NSColor.white.withAlphaComponent(0.7))}
            if let name=element.icon {
                if block.type == .hero && index==0 {fill(CGRect(x:18,y:y,width:24,height:24),color:NSColor(srgbRed:0.82,green:0.86,blue:0.92,alpha:0.65),radius:12)}
                let allocated=index==0 ? blockIcon:(icons[block.id+":item:"+String(max(0,index-1))] ?? name)
                icon(allocated,CGRect(x:20,y:y+3,width:18,height:18))
            }
            let inset:CGFloat=element.panel ? 12:0
            let box=CGRect(x:18+element.inset+inset,y:y+inset,width:rect.width-36-element.inset-inset*2,height:h-inset*2)
            context.saveGState();context.translateBy(x:box.minX,y:box.maxY);context.scaleBy(x:1,y:-1)
            let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed(element,centered:centered)),CFRange(),CGPath(rect:CGRect(origin:.zero,size:box.size),transform:nil),nil)
            context.textMatrix = .identity;CTFrameDraw(frame,context);context.restoreGState()
            guard CTFrameGetVisibleStringRange(frame).length==(element.text as NSString).length else {throw AIProcessingError.invalidSummary}
            y+=h+10
            if index==0 && diagram(block) {
                let diagramHeight=NativeVisualDiagramPainter.height(block,compact:false)
                NativeVisualDiagramPainter.draw(block,in:CGRect(x:18,y:y,width:rect.width-36,height:diagramHeight),context:context,printing:true,compact:false);y+=diagramHeight+10
            }
        }
    }
}

/// Render the complete SF Symbol catalogue in a transparent high-resolution
/// bitmap context before adding it to PDF. Text, cards and diagrams stay vector;
/// unsupported system symbols retain the earlier native-path fallback.
enum NativeVisualPDFSymbol {
    static func draw(_ name:String,in rect:CGRect,context:CGContext) {
        if let symbol=NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[NSColor(srgbRed:0.31,green:0.39,blue:0.44,alpha:1)])),
           let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:96,pixelsHigh:96,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
           let graphics=NSGraphicsContext(bitmapImageRep:bitmap) {
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
            symbol.draw(in:CGRect(x:0,y:0,width:96,height:96),from:.zero,operation:.copy,fraction:1)
            NSGraphicsContext.restoreGraphicsState()
            if let image=bitmap.cgImage {
                context.saveGState();context.translateBy(x:rect.minX,y:rect.maxY);context.scaleBy(x:1,y:-1)
                context.draw(image,in:CGRect(origin:.zero,size:rect.size));context.restoreGState();return
            }
        }
        context.saveGState();defer {context.restoreGState()}
        context.translateBy(x:rect.minX,y:rect.minY);context.scaleBy(x:rect.width/24,y:rect.height/24)
        context.setStrokeColor(NSColor(srgbRed:0.31,green:0.39,blue:0.44,alpha:1).cgColor)
        context.setLineWidth(1.7);context.setLineCap(.round);context.setLineJoin(.round)
        func line(_ points:[CGPoint]) {guard let first=points.first else{return};context.move(to:first);for point in points.dropFirst(){context.addLine(to:point)};context.strokePath()}
        func box(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat) {context.addPath(CGPath(roundedRect:CGRect(x:x,y:y,width:w,height:h),cornerWidth:2,cornerHeight:2,transform:nil));context.strokePath()}
        switch name {
        case "sparkles":
            line([.init(x:12,y:3),.init(x:14,y:9),.init(x:20,y:11),.init(x:14,y:13),.init(x:12,y:20),.init(x:10,y:13),.init(x:4,y:11),.init(x:10,y:9),.init(x:12,y:3)])
            line([.init(x:20,y:2),.init(x:20,y:6)]);line([.init(x:18,y:4),.init(x:22,y:4)])
        case "checkmark.circle","checkmark.seal":
            context.strokeEllipse(in:CGRect(x:2,y:2,width:20,height:20));line([.init(x:7,y:12),.init(x:11,y:16),.init(x:17,y:7)])
        case "text.bubble","quote.opening":
            box(2,3,20,14);line([.init(x:6,y:17),.init(x:6,y:22),.init(x:12,y:17)]);line([.init(x:6,y:8),.init(x:18,y:8)]);line([.init(x:6,y:12),.init(x:15,y:12)])
        case "clock":
            context.strokeEllipse(in:CGRect(x:2,y:2,width:20,height:20));line([.init(x:12,y:6),.init(x:12,y:12),.init(x:17,y:15)])
        case "chart.bar":
            box(3,13,4,8);box(10,7,4,14);box(17,2,4,19)
        case "questionmark.circle":
            context.strokeEllipse(in:CGRect(x:2,y:2,width:20,height:20));line([.init(x:8,y:8),.init(x:10,y:6),.init(x:14,y:6),.init(x:16,y:9),.init(x:12,y:13),.init(x:12,y:15)]);line([.init(x:12,y:18),.init(x:12,y:18.2)])
        case "exclamationmark.triangle":
            line([.init(x:12,y:2),.init(x:23,y:21),.init(x:1,y:21),.init(x:12,y:2)]);line([.init(x:12,y:8),.init(x:12,y:14)]);line([.init(x:12,y:17),.init(x:12,y:17.2)])
        case "arrow.right":line([.init(x:2,y:12),.init(x:22,y:12)]);line([.init(x:16,y:6),.init(x:22,y:12),.init(x:16,y:18)])
        case "point.3.connected.trianglepath.dotted":
            line([.init(x:12,y:4),.init(x:4,y:20),.init(x:20,y:20),.init(x:12,y:4)]);for point in [CGPoint(x:12,y:4),.init(x:4,y:20),.init(x:20,y:20)] {context.strokeEllipse(in:CGRect(x:point.x-2,y:point.y-2,width:4,height:4))}
        case "square.grid.2x2","tablecells":for x in [CGFloat(2),14] {for y in [CGFloat(2),14] {box(x,y,8,8)}}
        case "waveform":for (x,h) in [(3,6),(7,14),(11,20),(15,12),(19,6)] {line([.init(x:CGFloat(x),y:12-CGFloat(h)/2),.init(x:CGFloat(x),y:12+CGFloat(h)/2)])}
        default:
            for y in [CGFloat(5),12,19] {line([.init(x:3,y:y),.init(x:5,y:y)]);line([.init(x:9,y:y),.init(x:22,y:y)])}
        }
    }
}

/// One vector diagram painter shared by the SwiftUI-hosted NSView and PDF.
enum NativeVisualDiagramPainter {
    static func height(_ block:AIVisualBlock,compact:Bool)->CGFloat {
        if block.type == .chart {return block.chartKind == .horizontal || block.chartKind == .distribution ? CGFloat(block.items.count)*46+24:230}
        return compact ? CGFloat(block.items.count)*100:CGFloat((block.items.count+2)/3)*100
    }
    static func draw(_ block:AIVisualBlock,in rect:CGRect,context:CGContext,printing:Bool,compact:Bool) {
        context.saveGState();defer {context.restoreGState()}
        context.translateBy(x:rect.minX,y:rect.minY)
        let width=rect.width,height=rect.height
        let ink=printing ? NSColor.black:NSColor.labelColor
        let accent=NSColor(srgbRed:0.30,green:0.48,blue:0.64,alpha:1)
        func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,size:CGFloat=10) {
            let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
            let value=NSAttributedString(string:text,attributes:[.font:(NSFont(name:"ArialMT",size:size) ?? NSFont.systemFont(ofSize:size)),.foregroundColor:ink,.paragraphStyle:paragraph])
            context.saveGState();context.translateBy(x:x,y:y+32);context.scaleBy(x:1,y:-1)
            let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(location:0,length:0),CGPath(rect:CGRect(x:0,y:0,width:w,height:32),transform:nil),nil)
            context.textMatrix = .identity;CTFrameDraw(frame,context);context.restoreGState()
        }
        if block.type == .chart {
            let values=block.items.map {CGFloat($0.number ?? 0)},maxValue=max(1,values.map(abs).max() ?? 1)
            let kind=block.chartKind ?? .bar
            if kind == .horizontal || kind == .distribution {
                for (i,item) in block.items.enumerated() {
                    let y=CGFloat(i)*46
                    label(item.title,0,y,width*0.38)
                    context.setFillColor(accent.withAlphaComponent(0.85).cgColor)
                    context.fill(CGRect(x:width*0.4,y:y+4,width:(width*0.42)*abs(values[i])/maxValue,height:16))
                    label(item.value ?? "",width*0.84,y,width*0.16)
                }
            } else if kind == .donut {
                let sum=values.reduce(0,+),center=CGPoint(x:width*0.3,y:height*0.45),radius=min(width*0.22,height*0.34)
                var start:CGFloat = -.pi/2
                for (i,item) in block.items.enumerated() {
                    let end=start+(sum>0 ? values[i]/sum*2 * .pi:0)
                    context.setStrokeColor(accent.withAlphaComponent(CGFloat(0.35+0.65*Double(i+1)/Double(values.count))).cgColor);context.setLineWidth(radius*0.35);context.addArc(center:center,radius:radius,startAngle:start,endAngle:end,clockwise:false);context.strokePath();start=end
                    label(item.title+" · "+(item.value ?? ""),width*0.6,CGFloat(i)*34,width*0.4)
                }
            } else {
                let plotWidth=width-20,base=height-48,barWidth=plotWidth/CGFloat(max(values.count,1))
                var points=[CGPoint]()
                for (i,item) in block.items.enumerated() {
                    let x=10+CGFloat(i)*barWidth+barWidth/2,top=base-(base-30)*max(0,values[i])/maxValue
                    points.append(CGPoint(x:x,y:top))
                    if kind == .bar {context.setFillColor(accent.cgColor);context.fill(CGRect(x:x-barWidth*0.3,y:top,width:barWidth*0.6,height:max(1,base-top)))}
                    label(item.value ?? "",x-barWidth*0.45,max(0,top-28),barWidth*0.9)
                    label(item.date ?? item.title,x-barWidth*0.45,base+8,barWidth*0.9)
                }
                if kind == .line,let first=points.first {context.setStrokeColor(accent.cgColor);context.setLineWidth(2);context.move(to:first);for p in points.dropFirst(){context.addLine(to:p)};context.strokePath();for p in points {context.setFillColor(accent.cgColor);context.fillEllipse(in:CGRect(x:p.x-3,y:p.y-3,width:6,height:6))}}
            }
        } else {
            let columns=compact ? 1:min(3,max(1,block.items.count)),cellWidth=width/CGFloat(columns)
            let centers=block.items.indices.map {i in CGPoint(x:CGFloat(i%columns)*cellWidth+cellWidth/2,y:CGFloat(i/columns)*100+30)}
            for edge in block.edges ?? [] where centers.indices.contains(edge.from) && centers.indices.contains(edge.to) {
                let a=centers[edge.from],b=centers[edge.to]
                let angle=atan2(b.y-a.y,b.x-a.x)
                let distance=min((cellWidth*0.43+6)/max(0.001,abs(cos(angle))),32/max(0.001,abs(sin(angle))))
                let start=CGPoint(x:a.x+cos(angle)*distance,y:a.y+sin(angle)*distance)
                let target=CGPoint(x:b.x-cos(angle)*distance,y:b.y-sin(angle)*distance)
                context.setStrokeColor(accent.cgColor);context.setLineWidth(1.5);context.move(to:start);context.addLine(to:target);context.strokePath()
                context.move(to:target);context.addLine(to:CGPoint(x:target.x-cos(angle-0.5)*7,y:target.y-sin(angle-0.5)*7));context.move(to:target);context.addLine(to:CGPoint(x:target.x-cos(angle+0.5)*7,y:target.y-sin(angle+0.5)*7));context.strokePath()
                if !edge.label.isEmpty {
                    let labelWidth=min(120,cellWidth-12)
                    let horizontal=abs(a.y-b.y)<1
                    label(edge.label.count>30 ? String(edge.label.prefix(29))+"…":edge.label,horizontal ? (a.x+b.x)/2-labelWidth/2:(a.x+b.x)/2+12,horizontal ? a.y+34:(a.y+b.y)/2-16,labelWidth,size:9)
                }
            }
            for (i,item) in block.items.enumerated() {
                let c=centers[i],box=CGRect(x:c.x-cellWidth*0.43,y:c.y-24,width:cellWidth*0.86,height:52)
                context.setFillColor((printing ? NSColor(srgbRed:0.92,green:0.95,blue:0.97,alpha:1):NSColor.controlBackgroundColor).cgColor)
                context.addPath(CGPath(roundedRect:box,cornerWidth:8,cornerHeight:8,transform:nil));context.fillPath()
                context.setStrokeColor(accent.withAlphaComponent(0.5).cgColor);context.addPath(CGPath(roundedRect:box,cornerWidth:8,cornerHeight:8,transform:nil));context.strokePath()
                label(item.title,box.minX+10,box.minY+7,box.width-20,size:11)
            }
        }
    }
}
