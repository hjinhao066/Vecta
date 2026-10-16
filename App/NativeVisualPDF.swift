import AppKit
import CoreText

/// Uniform portrait A4: recording title, intact infographic, then saved text.
/// The infographic itself never reflows or splits between pages.
enum NativeVisualPDF {
    static func write(report:AIVisualSummary,title:String,date:Date?,duration:Double?,speakers:AIRecordingSpeakers,segments:[AISpeechSegment],textSummary:String?=nil,fullTextDocument:AIFullTextSummary?=nil,transcript:String?=nil,formatTitle:String?=nil,semantic:AISemanticSummary?=nil,to url:URL)throws {
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
        func attributed(_ text:String,size:CGFloat,weight:NSFont.Weight = .regular,color:NSColor?=nil)->NSAttributedString {
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=report.nativeStyle == .presentation ? 5:3;paragraph.paragraphSpacing=5
            return NSAttributedString(string:text,attributes:[.font:(NSFont(name:weight == .regular ? "ArialMT":"Arial-BoldMT",size:size) ?? NSFont.systemFont(ofSize:size,weight:weight)),.foregroundColor:color ?? textColor,.paragraphStyle:paragraph])
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
            var portrait=CGRect(x:0,y:0,width:595,height:842)
            let media=Data(bytes:&portrait,count:MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox:media] as CFDictionary);pageNumber+=1;y=46
            page=portrait
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
        try text(attributed(title.isEmpty ? report.title:title,size:22,weight:.bold),spacing:14)
        let composition=try NativeVisualComposer.make(report:report,speakers:speakers,formatTitle:formatTitle,semantic:semantic)
        let scale=width/NativeVisualComposition.size.width
        let visualHeight=NativeVisualComposition.size.height*scale
        if bottom-y<visualHeight {newPage()}
        context.saveGState()
        context.translateBy(x:46,y:842-y);context.scaleBy(x:scale,y:-scale)
        NativeVisualCanvasRenderer.draw(composition,in:context)
        context.restoreGState()
        y+=visualHeight
        var metadata=[String]()
        if let date {metadata.append(date.vectaFormatted(date:.long,time:.shortened))}
        if let duration,duration.isFinite,duration>0,duration<Double(Int.max)/2 {metadata.append(String(format:VL.text("Длительность: %d:%02d"),Int(duration)/60,Int(duration)%60))}
        if !metadata.isEmpty {_=draw(attributed(metadata.joined(separator:" · "),size:8,color:muted),rect:CGRect(x:46,y:792,width:width,height:14))}
        func appendixParagraph(_ raw:String)throws {
            for part in AITextDocument(raw).parts {
                if part.kind == .heading,bottom-y<95 {newPage()}
                let plain=AIExportText.plain(part.displayText)
                let rendered=(try? AttributedString(markdown:plain,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))).map {String($0.characters)} ?? plain
                try text(attributed(rendered,size:part.kind == .heading ? 14:11,weight:part.kind == .heading ? .bold:.regular),spacing:part.kind == .heading ? 6:12)
            }
        }
        if fullTextDocument != nil || (textSummary?.isEmpty == false) {
            // Exactly two body-line advances after the visual, without a forced page break.
            let bodyFont=NSFont(name:"ArialMT",size:11) ?? NSFont.systemFont(ofSize:11)
            y+=2*(bodyFont.ascender-bodyFont.descender+bodyFont.leading+(report.nativeStyle == .presentation ? 5:3))
            if let fullTextDocument {
                for paragraph in fullTextDocument.paragraphs {
                    if let heading=paragraph.heading,!heading.isEmpty {
                        if bottom-y<95 {newPage()}
                        try text(attributed(AIExportText.plain(heading),size:14,weight:.bold),spacing:6)
                    }
                    try appendixParagraph(speakers.render(paragraph.tokens))
                }
            } else {
                try appendixParagraph(textSummary ?? "")
            }
        }
        if !composition.omittedIDs.isEmpty {
            newPage()
            try text(attributed(VL.text("Полное содержание визуального отчёта"),size:18,weight:.bold))
            try text(attributed(composition.completeText,size:11))
        }
        if let transcript,!transcript.isEmpty {if bottom-y<180 {newPage()} else {y+=20};try text(attributed(VL.text("Расшифровка"),size:22,weight:.semibold));try text(attributed(transcript,size:11))}
        context.endPDFPage();context.closePDF();try (data as Data).write(to:url,options:.atomic)
    }
}

