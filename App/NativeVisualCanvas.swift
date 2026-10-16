import AppKit
import CoreText
import SwiftUI

/// Supported names from the existing SF Symbol catalog, cached for both outputs.
enum NativeVisualSymbolLibrary {
    static let supported=Set(AIVisualIconCatalog.symbols.filter {NSImage(systemSymbolName:$0,accessibilityDescription:nil) != nil})
    static func image(_ name:String,dark:Bool)->CGImage? {
        let configuration=NSImage.SymbolConfiguration(pointSize:26,weight:.regular)
            .applying(.init(paletteColors:[NativeVisualCanvasRenderer.ink(dark:dark,secondary:true)]))
        return NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(configuration)?.cgImage(forProposedRect:nil,context:nil,hints:nil)
    }
}

/// Draw in top-left logical coordinates. Only the caller's uniform CTM varies.
enum NativeVisualCanvasRenderer {
    static func ink(dark:Bool,secondary:Bool=false)->NSColor {
        if dark {return NSColor(srgbRed:secondary ? 0.73:0.94,green:secondary ? 0.78:0.96,blue:secondary ? 0.83:0.98,alpha:1)}
        return NSColor(srgbRed:secondary ? 0.31:0.075,green:secondary ? 0.35:0.09,blue:secondary ? 0.40:0.115,alpha:1)
    }
    static func preferredColor(_ role:NativeVisualComposition.Role)->Int {
        switch role {case .main,.thought:return 0;case .decision,.task,.outcome:return 6;case .metric,.comparison:return 5;case .quote,.warning:return 4;case .context:return 3}
    }
    /// Distinct decorative surfaces, not series or status encodings. Meaning stays in labels.
    static func paletteIndices(for document:NativeVisualComposition)->[Int] {
        let order=[4,5,0,6,3,7,8,2,9,10,11,1]
        var used=Set<Int>()
        return document.cards.map {card in
            let preferred=preferredColor(card.role)
            let index=used.contains(preferred) ? (order.first {!used.contains($0)} ?? preferred):preferred
            used.insert(index);return index
        }
    }
    static func fill(_ role:NativeVisualComposition.Role,dark:Bool,paletteIndex:Int?=nil)->NSColor {
        let index=paletteIndex ?? preferredColor(role)
        if dark {
            // Individually selected muted hues; the light palette must not collapse to navy.
            let colors:[(Double,Double,Double)]=[
                (0.16,0.25,0.29),(0.18,0.28,0.32),(0.17,0.27,0.24),
                (0.29,0.26,0.17),(0.31,0.20,0.24),(0.21,0.23,0.34),
                (0.23,0.29,0.17),(0.28,0.22,0.33),(0.32,0.24,0.18),
                (0.19,0.28,0.21),(0.28,0.25,0.21),(0.26,0.24,0.30)]
            let c=colors[index]
            return NSColor(srgbRed:c.0,green:c.1,blue:c.2,alpha:1)
        }
        let c=AIVisualEditorialPalette.color(index)
        return NSColor(srgbRed:c.red,green:c.green,blue:c.blue,alpha:1)
    }
    static func draw(_ document:NativeVisualComposition,in context:CGContext,dark:Bool=false) {
        context.saveGState();defer {context.restoreGState()}
        let bounds=CGRect(origin:.zero,size:NativeVisualComposition.size)
        context.setFillColor((dark ? NSColor(srgbRed:0.075,green:0.09,blue:0.12,alpha:1):.white).cgColor);context.fill(bounds)
        context.setStrokeColor(ink(dark:dark,secondary:true).withAlphaComponent(0.18).cgColor);context.setLineWidth(1)
        context.move(to:CGPoint(x:36,y:790));context.addLine(to:CGPoint(x:1164,y:790));context.strokePath()
        if let pill=document.categoryFrame {
            context.addPath(CGPath(roundedRect:pill,cornerWidth:8,cornerHeight:8,transform:nil))
            context.setFillColor(fill(.comparison,dark:dark).cgColor);context.fillPath()
        }
        let colors=paletteIndices(for:document)
        for (index,card) in document.cards.enumerated() {
            let path=CGPath(roundedRect:card.frame,cornerWidth:12,cornerHeight:12,transform:nil)
            context.addPath(path);context.setFillColor(fill(card.role,dark:dark,paletteIndex:colors[index]).cgColor);context.fillPath()
            context.addPath(path);context.setStrokeColor(ink(dark:dark,secondary:true).withAlphaComponent(0.16).cgColor);context.strokePath()
            for surface in card.surfaces {
                context.addPath(CGPath(roundedRect:surface.frame,cornerWidth:surface.style == .chip ? 10:5,cornerHeight:surface.style == .chip ? 10:5,transform:nil))
                context.setFillColor((dark ? NSColor.white.withAlphaComponent(0.055):NSColor.white.withAlphaComponent(surface.style == .quote ? 0.7:0.58)).cgColor);context.fillPath()
            }
            context.setStrokeColor(ink(dark:dark,secondary:true).withAlphaComponent(0.35).cgColor);context.setLineWidth(2)
            for rule in card.rules {context.move(to:rule.start);context.addLine(to:rule.end);context.strokePath()}
            for symbol in card.symbols {
                guard let image=NativeVisualSymbolLibrary.image(symbol.name,dark:dark) else {continue}
                context.saveGState()
                context.translateBy(x:symbol.frame.minX,y:symbol.frame.maxY);context.scaleBy(x:1,y:-1)
                let scale=min(symbol.frame.width/CGFloat(image.width),symbol.frame.height/CGFloat(image.height))
                let w=CGFloat(image.width)*scale,h=CGFloat(image.height)*scale
                context.draw(image,in:CGRect(x:(symbol.frame.width-w)/2,y:(symbol.frame.height-h)/2,width:w,height:h))
                context.restoreGState()
            }
        }
        for text in document.allText {
            guard !text.text.isEmpty else {continue}
            let value=NativeVisualTypesetter.attributed(text.text,size:text.size,bold:text.bold,color:ink(dark:dark,secondary:text.secondary),centered:text.centered)
            context.saveGState()
            context.translateBy(x:text.frame.minX,y:text.frame.maxY);context.scaleBy(x:1,y:-1)
            context.textMatrix = .identity
            let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(),CGPath(rect:CGRect(origin:.zero,size:text.frame.size),transform:nil),nil)
            CTFrameDraw(frame,context);context.restoreGState()
        }
    }
}

struct NativeVisualCanvas:NSViewRepresentable {
    let document:NativeVisualComposition
    let dark:Bool
    func makeNSView(context:Context)->Canvas {Canvas()}
    func updateNSView(_ view:Canvas,context:Context) {view.document=document;view.dark=dark;view.needsDisplay=true}
    final class Canvas:NSView {
        var document:NativeVisualComposition?
        var dark=false
        override var isFlipped:Bool {true}
        override func draw(_ dirtyRect:NSRect) {
            guard let document,let context=NSGraphicsContext.current?.cgContext else {return}
            let scale=min(bounds.width/1200,bounds.height/840)
            context.saveGState();context.scaleBy(x:scale,y:scale)
            NativeVisualCanvasRenderer.draw(document,in:context,dark:dark)
            context.restoreGState()
        }
    }
}
