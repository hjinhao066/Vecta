import AppKit
import SwiftUI

enum VectaAppearance:String,CaseIterable,Identifiable {
    case system,light,dark
    var id:String {rawValue}
    var title:String {switch self {case .system:return VL.text("Как в macOS");case .light:return VL.text("Светлая");case .dark:return VL.text("Тёмная")}}
    var scheme:ColorScheme? {switch self {case .system:return nil;case .light:return .light;case .dark:return .dark}}
}

/// Colour themes. Classic is the original neutral look; the others are adapted from AgentDeck's
/// reading themes (Starlight, Tokyo Night, Nord, Dracula, Gruvbox). Every text role is at least
/// 4.5:1 against the surfaces it sits on, in light and in dark.
enum VectaColorTheme:String,CaseIterable,Identifiable {
    case classic,starlight,tokyo,nord,dracula,gruvbox
    static let preferenceKey="vecta.colorTheme"
    var id:String {rawValue}
    var title:String {
        switch self {
        case .classic:return VL.text("Классическая")
        case .starlight:return "Starlight"
        case .tokyo:return "Tokyo Night"
        case .nord:return "Nord"
        case .dracula:return "Dracula"
        case .gruvbox:return "Gruvbox"
        }
    }
    static var current:VectaColorTheme {VectaColorTheme(rawValue:VL.preferences.string(forKey:preferenceKey) ?? "") ?? .classic}
    enum Role:CaseIterable {
        case canvas, sidebar, surface, elevated, hover, selection, border, text, secondary, muted, accent, onAccent, link, heading, subheading, strong, success, error, warning, code, codeBg, tableHead, tableHeadBg, rowAlt, quoteBar, markBg, mark
    }
    /// (light, dark) sRGB values per role.
    var palette:[Role:(UInt32,UInt32)] {
        switch self {
        case .classic: return [
            .canvas:(0xFAFAFA,0x090A0B), .sidebar:(0xF0F0F2,0x0E0F11), .surface:(0xF0F0F2,0x141517), .elevated:(0xE6E6E9,0x1B1C1F), .hover:(0xDADADD,0x252629),
            .selection:(0xD1D1D5,0x2B2C30), .border:(0xCCCCD2,0x292A2D), .text:(0x171719,0xF5F5F5), .secondary:(0x515157,0xA1A1A5), .muted:(0x626269,0x919198),
            .accent:(0x171719,0xF5F5F5), .onAccent:(0xFAFAFA,0x090A0B), .link:(0x2058C4,0x6AA8FF), .heading:(0x171719,0xF5F5F5), .subheading:(0x171719,0xF5F5F5),
            .strong:(0x171719,0xF5F5F5), .success:(0x18713B,0x4BC878), .error:(0xA72727,0xFF9393), .warning:(0x8A5A00,0xE8B44F), .code:(0x171719,0xF5F5F5),
            .codeBg:(0xE9E9EC,0x16171A), .tableHead:(0x171719,0xF5F5F5), .tableHeadBg:(0xE6E6E9,0x1B1C1F), .rowAlt:(0xF3F3F5,0x101113), .quoteBar:(0xA0A0A8,0x4A4B50),
            .markBg:(0xFBE7A1,0x4A3B12), .mark:(0x171719,0xF5F5F5)]
        case .starlight: return [
            .canvas:(0xF7F8FC,0x0B0F1E), .sidebar:(0xEFF0F5,0x131726), .surface:(0xEBECF2,0x191D2C), .elevated:(0xE3E5EB,0x212534), .hover:(0xDADCE4,0x2C303E),
            .selection:(0xD2D6EE,0x323A5A), .border:(0xCDCFD8,0x303443), .text:(0x1A2140,0xE4E8F5), .secondary:(0x394264,0xBAC2D8), .muted:(0x515C81,0x9BA5C2),
            .accent:(0x4A62E0,0x8FA6FF), .onAccent:(0xFFFFFF,0x0B0F1E), .link:(0x2F47C2,0x8FA6FF), .heading:(0x2F47C2,0x8FA6FF), .subheading:(0x835406,0xF0B450),
            .strong:(0x8A5200,0xFFD27A), .success:(0x1D6A41,0x6FD99A), .error:(0xA8332B,0xFE7F77), .warning:(0x835406,0xF0B450), .code:(0x0A6B5E,0x7FE0C8),
            .codeBg:(0xE9EDF7,0x161C33), .tableHead:(0x131A3A,0xFFD27A), .tableHeadBg:(0xE3E8F6,0x161C33), .rowAlt:(0xF1F3FA,0x0F1426), .quoteBar:(0x4A62E0,0x8FA6FF),
            .markBg:(0xFFD778,0xF0B450), .mark:(0x1A2140,0x0B0F1E)]
        case .tokyo: return [
            .canvas:(0xE6E7ED,0x1A1B26), .sidebar:(0xE0E1E8,0x20212D), .surface:(0xDCDEE5,0x252633), .elevated:(0xD6D8E0,0x2B2C3B), .hover:(0xCFD1DA,0x333545),
            .selection:(0xC1CAE1,0x37415D), .border:(0xC4C6D1,0x363949), .text:(0x343B58,0xC0CAF5), .secondary:(0x494F6D,0xA6AFDC), .muted:(0x4E5473,0xA2ACD9),
            .accent:(0x2E5BD0,0x7AA2F7), .onAccent:(0xFFFFFF,0x1A1B26), .link:(0x185D6C,0x2AC3DE), .heading:(0x62439D,0xBB9EF7), .subheading:(0x115C77,0x7DCFFF),
            .strong:(0x92400B,0xFF9E64), .success:(0x385F0D,0x9ECE6A), .error:(0x992E49,0xE198B7), .warning:(0x8A4011,0xFF9E64), .code:(0x385F0D,0x9ECE6A),
            .codeBg:(0xD8DAE4,0x24283B), .tableHead:(0x343B58,0xC0CAF5), .tableHeadBg:(0xD8DAE4,0x24283B), .rowAlt:(0xE0E1E8,0x1E2030), .quoteBar:(0x2E5BD0,0x7AA2F7),
            .markBg:(0xF2CF86,0xE0AF68), .mark:(0x343B58,0x1A1B26)]
        case .nord: return [
            .canvas:(0xECEFF4,0x2E3440), .sidebar:(0xE5E8EE,0x343A46), .surface:(0xE2E5EA,0x393F4B), .elevated:(0xDBDEE4,0x3F4551), .hover:(0xD3D7DD,0x484E59),
            .selection:(0xCDD5E0,0x4A5B67), .border:(0xC8CBD2,0x4B515D), .text:(0x2E3440,0xD8DEE9), .secondary:(0x3E4757,0xCAD2DF), .muted:(0x4C566A,0xC8D0DD),
            .accent:(0x58789F,0x88C0D0), .onAccent:(0xFFFFFF,0x2E3440), .link:(0x2C6274,0xBAD3E0), .heading:(0x2E6275,0xBAD3E0), .subheading:(0x3E5D8C,0xC5D1E0),
            .strong:(0x1A1F29,0xF4F7FB), .success:(0x466434,0xC5D2C8), .error:(0xA3343D,0xDCCAD3), .warning:(0x924529,0xDBCCC6), .code:(0x7A5A10,0xEBCB8B),
            .codeBg:(0xDFE4EC,0x3B4252), .tableHead:(0x2E3440,0xECEFF4), .tableHeadBg:(0xDDE2EA,0x3B4252), .rowAlt:(0xE6EAF0,0x323845), .quoteBar:(0x5E81AC,0x88C0D0),
            .markBg:(0xEBCB8B,0xEBCB8B), .mark:(0x2E3440,0x2E3440)]
        case .dracula: return [
            .canvas:(0xFFFBEB,0x282A36), .sidebar:(0xF7F3E4,0x2F313D), .surface:(0xF3EFE0,0x363742), .elevated:(0xEBE7D9,0x3D3F49), .hover:(0xE2DED0,0x474952),
            .selection:(0xDDD5DC,0x524A69), .border:(0xD4D1C4,0x4B4D56), .text:(0x1F1F1F,0xF8F8F2), .secondary:(0x413E59,0xCBCFE1), .muted:(0x5D5888,0xB9BEDA),
            .accent:(0x644AC9,0xBD93F9), .onAccent:(0xFFFFFF,0x282A36), .link:(0x05648C,0x8BE9FD), .heading:(0x05648C,0x8BE9FD), .subheading:(0x156C0B,0x50FA7B),
            .strong:(0xA34D14,0xFFB86C), .success:(0x156C0B,0x50FA7B), .error:(0xAB3325,0xFCAAA8), .warning:(0x964815,0xFFB86C), .code:(0x14710A,0x50FA7B),
            .codeBg:(0xF2ECD6,0x343746), .tableHead:(0x1F1F1F,0xF8F8F2), .tableHeadBg:(0xEFE8CF,0x383A4A), .rowAlt:(0xFAF5E2,0x2C2E3B), .quoteBar:(0x644AC9,0xBD93F9),
            .markBg:(0xF6E58A,0xF1FA8C), .mark:(0x1F1F1F,0x282A36)]
        case .gruvbox: return [
            .canvas:(0xFBF1C7,0x282828), .sidebar:(0xF4EBC2,0x2F2E2D), .surface:(0xF0E7BF,0x353431), .elevated:(0xEAE0BA,0x3C3A36), .hover:(0xE2D9B4,0x45433D),
            .selection:(0xE6CCA2,0x60442B), .border:(0xD7CEAB,0x49463F), .text:(0x3C3836,0xEBDBB2), .secondary:(0x4C4642,0xD2C2A1), .muted:(0x5A524C,0xC6B799),
            .accent:(0xAF3A03,0xFE8019), .onAccent:(0xFBF1C7,0x282828), .link:(0x0C6171,0xAEBDA7), .heading:(0x804D0A,0xFABD2F), .subheading:(0x5E5A00,0xBEBF37),
            .strong:(0xA53603,0xFE8827), .success:(0x5E5A00,0xBEBF37), .error:(0x9D0006,0xF4A68B), .warning:(0x9D3809,0xF6A85C), .code:(0x5E5A00,0xB8BB26),
            .codeBg:(0xEBDBB2,0x3C3836), .tableHead:(0x8B5000,0xFABD2F), .tableHeadBg:(0xEBDBB2,0x3C3836), .rowAlt:(0xF6EBC0,0x2E2C2B), .quoteBar:(0x7C6F64,0x928374),
            .markBg:(0xF5C84A,0xFABD2F), .mark:(0x3C3836,0x282828)]
        }
    }
}

enum Ink {
    private static let lock=NSLock()
    private static var cache:[String:Color]=[:]
    private static func color(_ light:UInt32,_ dark:UInt32)->Color {
        Color(nsColor:NSColor(name:nil) {appearance in
            let value=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
            return NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)
        })
    }
    /// Colours follow the chosen theme; the window rebuilds its views when the theme changes.
    static func tone(_ role:VectaColorTheme.Role,in theme:VectaColorTheme=VectaColorTheme.current)->Color {
        let key=theme.rawValue+"."+String(describing:role)
        lock.lock();defer {lock.unlock()}
        if let cached=cache[key] {return cached}
        let pair=theme.palette[role] ?? (0x808080,0x808080)
        let value=color(pair.0,pair.1);cache[key]=value
        return value
    }
    static var canvas:Color {tone(.canvas)}
    static var sidebar:Color {tone(.sidebar)}
    static var surface:Color {tone(.surface)}
    static var elevated:Color {tone(.elevated)}
    static var hover:Color {tone(.hover)}
    static var selection:Color {tone(.selection)}
    static var border:Color {tone(.border)}
    static var text:Color {tone(.text)}
    static var secondary:Color {tone(.secondary)}
    static var muted:Color {tone(.muted)}
    static var accent:Color {tone(.accent)}
    static var onAccent:Color {tone(.onAccent)}
    static var link:Color {tone(.link)}
    static var heading:Color {tone(.heading)}
    static var subheading:Color {tone(.subheading)}
    static var strong:Color {tone(.strong)}
    static var success:Color {tone(.success)}
    static var error:Color {tone(.error)}
    static var warning:Color {tone(.warning)}
    static var code:Color {tone(.code)}
    static var codeBg:Color {tone(.codeBg)}
    static var tableHead:Color {tone(.tableHead)}
    static var tableHeadBg:Color {tone(.tableHeadBg)}
    static var rowAlt:Color {tone(.rowAlt)}
    static var quoteBar:Color {tone(.quoteBar)}
    static var markBg:Color {tone(.markBg)}
    static var mark:Color {tone(.mark)}
}
