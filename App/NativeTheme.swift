import AppKit
import SwiftUI

enum VectaAppearance:String,CaseIterable,Identifiable {
    case system,light,dark
    var id:String {rawValue}
    var title:String {switch self {case .system:return VL.text("Как в macOS");case .light:return VL.text("Светлая");case .dark:return VL.text("Тёмная")}}
    var scheme:ColorScheme? {switch self {case .system:return nil;case .light:return .light;case .dark:return .dark}}
}
enum Ink {
    private static func color(_ light:UInt32,_ dark:UInt32)->Color {
        Color(nsColor:NSColor(name:nil) {appearance in
            let value=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
            return NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)
        })
    }
    static let canvas=color(0xFAFAFA,0x090A0B),sidebar=color(0xF0F0F2,0x0E0F11),surface=color(0xF0F0F2,0x141517)
    static let elevated=color(0xE6E6E9,0x1B1C1F),hover=color(0xDADADD,0x252629),selection=color(0xD1D1D5,0x2B2C30)
    static let text=color(0x171719,0xF5F5F5),secondary=color(0x515157,0xA1A1A5),muted=color(0x626269,0x919198)
    static let error=color(0xA72727,0xFF9393)
    static let border=color(0xCCCCD2,0x292A2D),success=color(0x18713B,0x4BC878)
}
