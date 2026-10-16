import AppKit
import PDFKit

/// Synthetic only: never reads owner recordings, models, preferences or devices.
enum NativeVisualCompositionChecks {
    struct Failure:Error {let message:String}
    static func fixture(_ family:NativeVisualComposition.Family)->AIVisualSummary {
        func item(_ title:String,_ body:String,_ value:String?=nil)->AIVisualItem {
            .init(title:title,tokens:[.init(text:body,speakerID:nil)],sourceSegments:[],value:value)
        }
        func block(_ id:String,_ type:AIVisualBlockType,_ title:String,_ items:[AIVisualItem])->AIVisualBlock {
            .init(id:id,type:type,title:title,items:items,role:.fact)
        }
        let hero=block("hero",.hero,"Проверка до запуска",[item("Сначала проверка, затем запуск","Публикация возможна только после проверки передачи файлов и восстановления данных.")])
        let thought=block("thought",.keyPoints,"Независимость",[item("Локальная обработка","Звук и текст остаются на Mac. Интернет не требуется для анализа.")])
        let warning=block("warning",.risks,"Ограничение",[item("Не удалять исходники","Исходные записи нужно сохранить до завершения проверки.")])
        let decisions=block("decisions",.decisions,"Решение",[item("Проверить восстановление","Сначала подтвердить возможность восстановления из резервной копии.")])
        let tasks=block("tasks",.tasks,"Задачи",[item("Отчёт к пятнице","Подготовить отчёт после проверки. Срок: пятница.")])
        let blocks:[AIVisualBlock]
        switch family {
        case .hero:blocks=[hero,thought,warning]
        case .comparison:blocks=[block("compare",.comparison,"Два варианта",[item("Привычный выбор","Вариант с ограниченным бюджетом.","30 000 ₽"),item("Рыночная возможность","Вариант требует проверки условий.","90 000 ₽")])]
        case .timeline:blocks=[block("stages",.timeline,"Последовательность",[item("Проверить","Проверить исходные файлы."),item("Сопоставить","Сопоставить контрольные суммы."),item("Сохранить","Сохранить проверенный результат.")])]
        case .actions:blocks=[decisions,tasks,warning]
        case .metrics:blocks=[block("metrics",.statistics,"Показатели",[item("Участники","Согласовали следующий шаг.","12 человек"),item("Срок","На проверку выделено три дня.","3 дня"),item("Бюджет","Бюджет утверждён на пилот.","45 000 ₽")])]
        case .balanced:blocks=[thought,warning,block("quote",.quotes,"Прямая речь",[item("Участник","Лучше сначала проверить, а потом запускать.")])]
        case .causal:
            var flow=block("cause",.processFlow,"Связь",[item("Проблема","Передача прерывается."),item("Причина","Соединение нестабильно."),item("Решение","Повторить передачу по кабелю.")])
            flow.edges=[.init(from:0,to:1,label:"причина",sourceSegments:[1]),.init(from:1,to:2,label:"решение",sourceSegments:[1])]
            blocks=[flow]
        }
        return .init(schemaVersion:3,title:"Проверка перед запуском",theme:"editorial",blocks:blocks,subtitle:"Синтетический пример · никакие реальные записи не использованы",category:"Обзор записи",nativeStyle:.editorial)
    }
    static func run(artifacts:URL?=nil)throws {
        try NativeExportChecks.run()
        var assertions=0
        func check(_ value:Bool,_ message:String)throws {assertions+=1;if !value {throw Failure(message:message)}}
        let speakers=AIRecordingSpeakers()
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let bounds=CGRect(origin:.zero,size:NativeVisualComposition.size)
        for family in NativeVisualComposition.Family.allCases {
            let report=fixture(family),saved=try encoder.encode(report)
            let doc=try NativeVisualComposer.make(report:report,speakers:speakers)
            try check(doc.family==family,"Wrong automatic family: \(family) -> \(doc.family)")
            try check(!doc.cards.isEmpty && doc.cards.count<=7,"Bounded nonempty cards")
            try check(doc.fingerprint == NativeVisualComposer.make(report:report,speakers:speakers).fingerprint,"Deterministic geometry")
            try check(saved == encoder.encode(report),"Saved report unchanged")
            for card in doc.cards {
                try check(bounds.contains(card.frame),"Card inside canvas")
                try check(!card.texts.isEmpty,"No empty card")
                for text in card.texts {try check(card.frame.contains(text.frame) && NativeVisualTypesetter.fits(text) && text.size>=16,"Full readable text inside card")}
            }
            for i in doc.cards.indices {for j in doc.cards.indices where j>i {try check(!doc.cards[i].frame.intersects(doc.cards[j].frame),"No overlap")}}
            let colors=NativeVisualCanvasRenderer.paletteIndices(for:doc)
            try check(Set(colors).count==doc.cards.count,"Every visible card has a distinct pastel")
            try check(colors==NativeVisualCanvasRenderer.paletteIndices(for:doc),"Palette is deterministic")
            for dark in [false,true] {
                for (index,card) in doc.cards.enumerated() {
                    let fill=NativeVisualCanvasRenderer.fill(card.role,dark:dark,paletteIndex:colors[index])
                    try check(contrast(NativeVisualCanvasRenderer.ink(dark:dark,secondary:true),fill)>=4.5,"Distinct surface caption contrast")
                }
                for role in NativeVisualComposition.Role.allValues {
                    try check(contrast(NativeVisualCanvasRenderer.ink(dark:dark),NativeVisualCanvasRenderer.fill(role,dark:dark))>=4.5,"Body contrast")
                    try check(contrast(NativeVisualCanvasRenderer.ink(dark:dark,secondary:true),NativeVisualCanvasRenderer.fill(role,dark:dark))>=4.5,"Caption contrast")
                }
            }
            if let artifacts {
                for dark in [false,true] {try render(doc,to:artifacts.appendingPathComponent(family.rawValue+(dark ? "-dark":"-light")+".png"),dark:dark)}
                let url=artifacts.appendingPathComponent(family.rawValue+".pdf")
                try NativeVisualPDF.write(report:report,title:report.title,date:nil,duration:300,speakers:speakers,segments:[],to:url)
                let pdf=PDFDocument(url:url)
                try check(pdf?.pageCount==1,"Infographic is one PDF page")
                try check(pdf?.page(at:0)?.bounds(for:.mediaBox).size == CGSize(width:595,height:842),"Portrait A4 visual PDF page")
                try check(pdf?.string?.contains("Проверка перед запуском")==true,"PDF text selectable")
                if family == .comparison {try check(pdf?.string?.contains("90 000 ₽")==true,"Exact metric selectable")}
            }
        }
        for semantic in [false,true] {
            let context=NativeExportChecks.fixture(tag:"CANVAS",semantic:semantic)
            let projected=context.projection(.visualSummary)!.visual!
            let original=context.result.semanticSummary?.visual(style:.editorial) ?? context.result.visualSummary!
            let ui=try NativeVisualComposer.make(report:original,speakers:context.speakers,formatTitle:context.result.request.format.displayTitle,semantic:context.result.semanticSummary)
            let pdf=try NativeVisualComposer.make(report:projected,speakers:context.speakers,formatTitle:context.result.request.format.displayTitle,semantic:context.result.semanticSummary)
            try check(ui.fingerprint==pdf.fingerprint,"App/export snapshot geometry is identical for semantic and legacy")
            try check(ui.completeText.contains("literal speaker_001 QUOTE_CANVAS"),"Literal quotes are not name-replaced")
        }
        let events=AISemanticSummary(schemaVersion:1,title:"Этапы",entries:(0..<3).map {i in
            AISemanticEntry(id:"event-\(i)",kind:.event,title:"Этап \(i)",tokens:[.init(text:"Проверка этапа \(i).",speakerID:nil)],sourceSegments:[])
        })
        let eventDoc=try NativeVisualComposer.make(report:events.visual(style:.editorial),speakers:speakers,semantic:events)
        try check(eventDoc.family == .timeline,"Promoted hero does not destroy original event kind")
        try referenceRegressions(speakers:speakers,artifacts:artifacts,check:check)
        try a4FlowRegressions(speakers:speakers,artifacts:artifacts,check:check)
        let longTitle=String(repeating:"Длинный заголовок ",count:9)
        let titleReport=AIVisualSummary(schemaVersion:3,title:longTitle,theme:"editorial",blocks:fixture(.hero).blocks)
        let titled=try NativeVisualComposer.make(report:titleReport,speakers:speakers)
        try check(titled.allText.allSatisfy(NativeVisualTypesetter.fits),"Long Cyrillic heading wraps without clipping")
        var report=fixture(.hero)
        let longItem=AIVisualItem(title:"Не терять исходный материал",tokens:[.init(text:String(repeating:"Не удалять 42 файла до 17 октября. ",count:400),speakerID:nil)],sourceSegments:[],deadline:"17 октября")
        report = .init(schemaVersion:3,title:report.title,theme:"editorial",blocks:report.blocks+[.init(id:"huge",type:.tasks,title:"Обязательство",items:[longItem])])
        let budget=try NativeVisualComposer.make(report:report,speakers:speakers)
        try check(budget.cards.count<=7 && budget.completeText.contains("17 октября"),"Oversize data retained outside canvas")
        let uniqueLong=(0..<400).map {"Обязательство номер \($0): не удалять файлы до проверки."}.joined(separator:" ")
        let huge=AIVisualItem(title:"Длинное обязательство",tokens:[.init(text:uniqueLong,speakerID:nil)],sourceSegments:[])
        report = .init(schemaVersion:3,title:"Длинный отчёт",theme:"editorial",blocks:[.init(id:"unfit",type:.tasks,title:"Задача",items:[huge])]+fixture(.hero).blocks)
        let recovered=try NativeVisualComposer.make(report:report,speakers:speakers)
        try check(recovered.omittedIDs.contains("unfit/0") && !recovered.cards.isEmpty,"Oversize high-priority item does not suppress every other card")
        try check(recovered.completeText.contains(uniqueLong),"Whole omitted content retained")
        var dense=fixture(.balanced)
        dense = .init(schemaVersion:3,title:"Плотный отчёт",theme:"editorial",blocks:(0..<64).map {i in
            .init(id:"entry-\(i)",type:i%3==0 ? .decisions:.keyPoints,title:"Тема \(i)",items:[.init(title:"Результат \(i)",tokens:[.init(text:"Согласован пункт \(i). Не менять исходные данные.",speakerID:nil)],sourceSegments:[])])
        })
        let selected=try NativeVisualComposer.make(report:dense,speakers:speakers)
        try check(selected.cards.count<=7 && selected.omittedIDs.count>=57,"64 entries respect editorial budget")
        try check(selected.completeText.contains("Согласован пункт 63."),"Last fact is retained")
        let empty=try NativeVisualComposer.make(report:.init(schemaVersion:1,title:"Пустой отчёт",theme:"editorial",blocks:[]),speakers:speakers)
        try check(empty.cards.isEmpty && empty.allText.allSatisfy(NativeVisualTypesetter.fits),"Empty state without fake cards")
        var noCauseBlock=fixture(.causal).blocks[0];noCauseBlock.edges=[]
        let noCause=AIVisualSummary(schemaVersion:3,title:"Без причинной связи",theme:"editorial",blocks:[noCauseBlock])
        try check(NativeVisualComposer.make(report:noCause,speakers:speakers).family != .causal,"No fabricated causality")
        if let artifacts {
            try NativeVisualPDF.write(report:dense,title:dense.title,date:nil,duration:10800,speakers:speakers,segments:[],to:artifacts.appendingPathComponent("dense.pdf"))
            let densePDF=PDFDocument(url:artifacts.appendingPathComponent("dense.pdf"))
            try check((densePDF?.pageCount ?? 0)>1,"Dense report has one visual canvas plus full omitted facts")
            try check(densePDF?.string?.contains("Согласован пункт 63.")==true,"Omitted facts are in selectable PDF appendix")
            let appendix=String(repeating:"Сохранённый полный текст: не удалять исходные материалы до завершения проверки.\n\n",count:100)
            let url=artifacts.appendingPathComponent("full-report.pdf")
            try NativeVisualPDF.write(report:dense,title:dense.title,date:nil,duration:300,speakers:speakers,segments:[],textSummary:appendix,to:url)
            let full=PDFDocument(url:url)
            try check((full?.pageCount ?? 0)>1 && full?.string?.contains("Сохранённый полный текст")==true,"Full text continues without changing canvas")
            try check(full?.page(at:0)?.string?.contains("Сохранённый полный текст")==true,"Summary precedes omitted-visual appendix on first page")
            if let full {for i in 0..<full.pageCount {try check(full.page(at:i)?.bounds(for:.mediaBox).size == CGSize(width:595,height:842),"Uniform A4 including omitted-visual appendix")}}
        }
        print("PASS \(assertions) fixed-canvas composition/geometry/contrast/preservation/PDF checks; synthetic only")
    }
    private static func a4FlowRegressions(speakers:AIRecordingSpeakers,artifacts:URL?,check:(Bool,String)throws->Void)throws {
        let document=AIFullTextSummary(schemaVersion:1,paragraphs:[
            .init(id:"first",heading:"Core Synopsis",tokens:[.init(text:"Обычный текст без жирного начертания. Сохранённый смысл не меняется.",speakerID:nil)],sourceSegments:[]),
            .init(id:"next",heading:"Next section",tokens:[.init(text:"Короткий абзац.",speakerID:nil)],sourceSegments:[])])
        let plain=document.rendered(speakers:speakers)
        let markdown=document.rendered(speakers:speakers,markdownHeadings:true)
        let parts=AITextDocument(markdown).parts
        try check(!plain.contains("## ") && markdown.contains("## Core Synopsis"),"TXT/copy stay plain; display retains explicit headings")
        try check(parts.filter {$0.kind == .heading}.map(\.text)==["Core Synopsis","Next section"],"Explicit short-paragraph headings retained")
        try check(parts.filter {$0.kind == .paragraph}.count==2,"Body paragraphs remain regular")
        let repeated=AIVisualSummary(schemaVersion:3,title:"Разные оттенки",theme:"editorial",blocks:(0..<7).map {i in
            .init(id:"thought-\(i)",type:.keyPoints,title:"Тема \(i)",items:[.init(title:"Мысль \(i)",tokens:[.init(text:"Сохранённый факт \(i).",speakerID:nil)],sourceSegments:[])])})
        let composition=try NativeVisualComposer.make(report:repeated,speakers:speakers)
        let colors=NativeVisualCanvasRenderer.paletteIndices(for:composition)
        try check(composition.cards.count==7 && Set(colors).count==7,"Seven same-role panels still have seven colors")
        for dark in [false,true] {
            let fills=colors.map {NativeVisualCanvasRenderer.fill(.thought,dark:dark,paletteIndex:$0)}
            try check(Set(fills.map {$0.description}).count==7,"Distinct hues in both themes")
            for fill in fills {
                try check(contrast(NativeVisualCanvasRenderer.ink(dark:dark,secondary:true),fill)>=4.5,"Every palette entry passes caption contrast")
            }
        }
        guard let artifacts else {return}
        for dark in [false,true] {try render(composition,to:artifacts.appendingPathComponent("same-role"+(dark ? "-dark":"-light")+".png"),dark:dark)}
        let report=fixture(.hero)
        let url=artifacts.appendingPathComponent("a4-flow.pdf")
        try NativeVisualPDF.write(report:report,title:"06-03 Непринуждённый разговор: Экзамены и самооценка",date:nil,duration:nil,speakers:speakers,segments:[],fullTextDocument:document,to:url)
        guard let pdf=PDFDocument(url:url),let first=pdf.page(at:0) else {throw Failure(message:"A4 PDF missing")}
        try check(pdf.pageCount==1 && first.string?.contains("Core Synopsis")==true,"Summary begins on visual page")
        func selection(_ text:String)->PDFSelection? {
            guard let value=first.string else {return nil}
            let range=(value as NSString).range(of:text)
            return range.location==NSNotFound ? nil:first.selection(for:range)
        }
        guard let heading=selection("Core Synopsis"),let body=selection("Обычный текст без жирного начертания.") else {throw Failure(message:"Selectable heading/body missing")}
        let headingFonts=heading.attributedString?.attributes(at:0,effectiveRange:nil)[.font] as? NSFont
        let bodyFont=body.attributedString?.attributes(at:0,effectiveRange:nil)[.font] as? NSFont
        try check(headingFonts?.fontDescriptor.symbolicTraits.contains(.bold)==true,"PDF heading is bold")
        try check(bodyFont?.fontDescriptor.symbolicTraits.contains(.bold)==false,"PDF body is regular")
        let visual=try NativeVisualComposer.make(report:report,speakers:speakers)
        if let footer=selection(visual.footer.text) {
            let gap=footer.bounds(for:first).minY-heading.bounds(for:first).maxY
            try check(gap>=20 && gap<80,"Two-line separation below visual, not a new page")
        } else {throw Failure(message:"Selectable visual footer missing")}
        let pageBounds=first.bounds(for:.mediaBox)
        guard let context=CGContext(data:nil,width:1190,height:1684,bitsPerComponent:8,bytesPerRow:1190*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw Failure(message:"A4 proof context")}
        context.scaleBy(x:2,y:2);context.setFillColor(NSColor.white.cgColor);context.fill(pageBounds);first.draw(with:.mediaBox,to:context)
        if let image=context.makeImage(),let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {try data.write(to:artifacts.appendingPathComponent("a4-flow-page-1.png"))}
        let long=AIFullTextSummary(schemaVersion:1,paragraphs:document.paragraphs+[
            .init(id:"long",heading:"Long section",tokens:[.init(text:(0..<400).map {"Сохранённый пункт \($0): исходные данные не изменяются."}.joined(separator:" "),speakerID:nil)],sourceSegments:[])])
        let longURL=artifacts.appendingPathComponent("a4-long-flow.pdf")
        try NativeVisualPDF.write(report:report,title:report.title,date:nil,duration:nil,speakers:speakers,segments:[],fullTextDocument:long,transcript:"TRANSCRIPT_END_MARKER",to:longURL)
        guard let all=PDFDocument(url:longURL) else {throw Failure(message:"Long PDF missing")}
        try check(all.pageCount>2 && all.string?.contains("Сохранённый пункт 399:")==true && all.string?.contains("TRANSCRIPT_END_MARKER")==true,"Long summary and transcript retained through pagination")
        for i in 0..<all.pageCount {try check(all.page(at:i)?.bounds(for:.mediaBox).size==CGSize(width:595,height:842),"Every PDF page is identical portrait A4")}
    }
    private static func referenceRegressions(speakers:AIRecordingSpeakers,artifacts:URL?,check:(Bool,String)throws->Void)throws {
        func item(_ title:String,_ body:String,_ value:String?=nil)->AIVisualItem {
            .init(title:title,tokens:body.isEmpty ? []:[.init(text:body,speakerID:nil)],sourceSegments:[],value:value)
        }
        func block(_ id:String,_ type:AIVisualBlockType,_ title:String,_ items:[AIVisualItem])->AIVisualBlock {
            .init(id:id,type:type,title:title,items:items,role:.fact)
        }
        let reference=AIVisualSummary(schemaVersion:3,title:"Экзамены и самооценка",theme:"editorial",blocks:[
            block("trap",.keyPoints,"Внешняя оценка",[item("Экзамен — не оценка личности","Низкий балл воспринимается как закрытие жизненных путей. В разговоре предложено отделять результат экзамена от собственной ценности.")]),
            block("boundaries",.keyPoints,"Границы диплома",[item("Образование важно, но не везде","Медицина и юриспруденция требуют диплома. Другие профессиональные пути обсуждаются отдельно.")]),
            block("price",.statistics,"Рыночный ориентир",[item("Реальные вакансии","Ориентир из разговора; условия ещё нужно проверить.","90 000 ₽")]),
            block("quote",.quotes,"Прямая речь",[item("Оценка и возможности","Человек переносит балл на собственную ценность, сужая горизонт возможностей.")]),
            block("change",.risks,"Ловушка сравнения",[item("Не превращать эпизод в приговор","Внешняя оценка не доказывает, что другие пути закрыты.")])
        ],subtitle:"Анализ личных границ · синтетический пример",category:"Психологический разбор",nativeStyle:.editorial)
        let doc=try NativeVisualComposer.make(report:reference,speakers:speakers)
        try check(doc.cards.count==5,"Reference-density fixture retains all five analytical panels")
        try check(doc.family == .balanced,"Reference-density automatic family")
        try check(doc.cards[0].frame.width != doc.cards[1].frame.width,"Asymmetric reference panels")
        try check(doc.categoryFrame != nil && doc.cards.allSatisfy {!$0.symbols.isEmpty},"Topic pill and catalog icon badges")
        try check(doc.cards.contains {$0.surfaces.contains {$0.style == .quote}},"Quotation inset is rendered")
        try check(doc.cards.contains {$0.role == .metric && $0.texts.contains {$0.size>=48 && $0.centered}},"Centered headline metric")
        for card in doc.cards {
            try check(AIVisualComponentRegistry.components.contains {$0.id==card.componentID},"Reuse registered component descriptor")
            try check(card.symbols.allSatisfy {NativeVisualSymbolLibrary.supported.contains($0.name)},"Supported existing catalog symbols only")
            try check(card.role == .decision || card.symbols.allSatisfy {!$0.name.hasPrefix("checkmark")},"No false completed-decision symbolism")
            try check(card.surfaces.allSatisfy {card.frame.contains($0.frame)},"Inset geometry bounded")
        }
        try check(AIVisualIconCatalog.symbols.count==128 && Set(AIVisualIconCatalog.symbols).count==128,"Original 128-symbol vocabulary retained")
        try check(AIVisualIconCatalog.preferred("budget market").first=="banknote","English aliases live in central catalog")
        try check(NativeVisualSymbolLibrary.image("banknote",dark:false) != nil,"Symbols resolve to drawable image")
        let allocated=AIVisualIconCatalog.allocate(reference,supported:NativeVisualSymbolLibrary.supported)
        try check(AIVisualIconCatalog.families[13].1.contains(allocated["price:item:0"] ?? ""),"Metric badge has a quantitative rather than quotation meaning")
        try check(AIVisualIconCatalog.families[3].1.contains(allocated["change:item:0"] ?? ""),"Warning badge preserves risk meaning")
        let numeric=AIVisualItem(title:"Измерение",tokens:[],sourceSegments:[],number:42.125,unit:"ms")
        let numberReport=AIVisualSummary(schemaVersion:1,title:"Число без value",theme:"editorial",blocks:[block("legacy",.chart,"Задержка",[numeric])])
        let numberDoc=try NativeVisualComposer.make(report:numberReport,speakers:speakers)
        try check(numberDoc.readableText.contains("42.125 ms") && numberDoc.completeText.contains("42.125 ms"),"Number-only legacy claim survives editorial/canvas/full text")
        let groups=AIVisualSummary(schemaVersion:3,title:"Разные сравнения",theme:"editorial",blocks:[
            block("budget",.comparison,"Бюджет",[item("Пилот","Стоимость пилота.","30 000 ₽"),item("Запуск","Стоимость запуска.","90 000 ₽")]),
            block("time",.comparison,"Время",[item("Ручной","Ручная проверка.","3 дня"),item("Автоматический","Автоматическая проверка.","1 день")])])
        let grouped=try NativeVisualComposer.make(report:groups,speakers:speakers)
        try check(grouped.cards.count==4 && grouped.completeText.contains("Бюджет") && grouped.completeText.contains("Время"),"Independent comparison groups are retained")
        for prefix in ["budget/","time/"] {let count=grouped.cards.filter {$0.id.hasPrefix(prefix)}.count;try check(count==0 || count==2,"Legacy comparison sides stay atomic")}
        let sameSides=AIVisualSummary(schemaVersion:3,title:"Общие варианты — разные контексты",theme:"editorial",blocks:[
            block("first",.comparison,"Бюджет команды",[item("A","Первый вариант.","10"),item("B","Второй вариант.","20")]),
            block("second",.comparison,"Бюджет продукта",[item("A","Первый вариант.","10"),item("B","Второй вариант.","20")])])
        let independent=try NativeVisualComposer.make(report:sameSides,speakers:speakers)
        try check(independent.cards.count==4,"Identical sides in distinct contexts are not deduplicated across groups")
        let semantic=AISemanticSummary(schemaVersion:1,title:"Независимые сопоставления",entries:(0..<4).map {i in
            .init(id:"comparison-\(i)",kind:.comparison,title:"Контекст \(i)",tokens:[.init(text:"Отдельное сопоставление \(i): вариант А дороже варианта Б.",speakerID:nil)],sourceSegments:[])
        })
        let semanticDoc=try NativeVisualComposer.make(report:semantic.visual(style:.editorial),speakers:speakers,semantic:semantic)
        try check(semanticDoc.cards.count==4,"Four semantic comparisons are not merged then dropped")
        for i in 0..<4 {try check(semanticDoc.readableText.contains("Контекст \(i)"),"Semantic comparison heading preserved")}
        var multiline=reference
        multiline = .init(schemaVersion:3,title:String(repeating:"Тема\n",count:32),theme:"editorial",blocks:reference.blocks,category:String(repeating:"Раздел\n",count:12))
        let header=try NativeVisualComposer.make(report:multiline,speakers:speakers)
        try check(header.cards.allSatisfy {card in header.heading.allSatisfy {!$0.frame.intersects(card.frame)}},"Multiline valid title/category never intersects canvas content")
        let huge=AIVisualItem(title:"Сохранить 42 файла",tokens:[.init(text:(0..<400).map {"Обязательство \($0): не удалять исходники."}.joined(separator:" "),speakerID:nil)],sourceSegments:[],deadline:"17 октября")
        let coverage=try NativeVisualComposer.make(report:.init(schemaVersion:3,title:"Проверка покрытия",theme:"editorial",blocks:reference.blocks+[block("huge",.tasks,"Обязательство",[huge])]),speakers:speakers)
        try check(coverage.omittedIDs.contains("huge/0") && coverage.footer.text.contains("обязательств и рисков: 1"),"Oversized commitment explicitly disclosed in coverage")
        try check(coverage.completeText.contains("Обязательство 399:") && coverage.completeText.contains("17 октября"),"Full commitment and exact deadline remain available")
        if let artifacts {
            for dark in [false,true] {try render(doc,to:artifacts.appendingPathComponent("reference-analytical"+(dark ? "-dark":"-light")+".png"),dark:dark)}
            try NativeVisualPDF.write(report:reference,title:reference.title,date:nil,duration:nil,speakers:speakers,segments:[],to:artifacts.appendingPathComponent("reference-analytical.pdf"))
            try NativeVisualPDF.write(report:numberReport,title:numberReport.title,date:nil,duration:nil,speakers:speakers,segments:[],to:artifacts.appendingPathComponent("legacy-number.pdf"))
            try check(PDFDocument(url:artifacts.appendingPathComponent("legacy-number.pdf"))?.string?.contains("42.125 ms")==true,"Legacy numeric PDF text selectable")
        }
    }
    private static func contrast(_ a:NSColor,_ b:NSColor)->Double {
        func luminance(_ c:NSColor)->Double {
            let c=c.usingColorSpace(.sRGB)!
            func linear(_ v:CGFloat)->Double {let x=Double(v);return x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
            return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
        }
        let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
    static func render(_ document:NativeVisualComposition,to url:URL,dark:Bool)throws {
        let width=1200,height=840
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw Failure(message:"Bitmap context")}
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        NativeVisualCanvasRenderer.draw(document,in:context,dark:dark)
        guard let image=context.makeImage(),let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw Failure(message:"PNG output")}
        try data.write(to:url)
    }
}

private extension NativeVisualComposition.Role {
    static var allValues:[Self] {[.main,.thought,.decision,.task,.metric,.comparison,.quote,.warning,.context,.outcome]}
}

#if VECTA_VISUAL_STANDALONE
@main struct VisualCompositionCheckMain {
    static func main()throws {
        let target=CommandLine.arguments.count>1 ? URL(fileURLWithPath:CommandLine.arguments[1]):nil
        if let target {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)}
        try NativeVisualCompositionChecks.run(artifacts:target)
    }
}
#endif
