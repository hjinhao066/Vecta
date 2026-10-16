import AppKit
import SwiftUI

extension AISpeechSegment: Identifiable {}

extension View {
    @ViewBuilder func vectaFocusStyle() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() }
        else { self }
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}
struct QuietButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundColor(primary ? Ink.canvas : Ink.text)
            .background(primary ? Ink.text.opacity(configuration.isPressed ? 0.8 : 1) : (configuration.isPressed ? Ink.hover : Ink.elevated))
            .cornerRadius(7)
    }
}
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let value = Int(seconds); return String(format: "%d:%02d", value / 60, value % 60)
}
struct ScreenTitle: View {
    let title: String; var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundColor(Ink.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

