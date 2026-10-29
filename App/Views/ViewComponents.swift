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
            .foregroundColor(primary ? Ink.onAccent : Ink.text)
            .background(primary ? Ink.accent.opacity(configuration.isPressed ? 0.8 : 1) : (configuration.isPressed ? Ink.hover : Ink.elevated))
            .cornerRadius(7)
    }
}
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let value = Int(seconds); return String(format: "%d:%02d", value / 60, value % 60)
}
/// Start and end of a recording, e.g. "Oct 28, 2026 at 5:04 PM – 9:23 PM". The end repeats its date
/// when the recording runs past midnight. Without a known duration only the start is shown.
func timeRange(from start: Date, duration: Double, date: Date.FormatStyle.DateStyle = .abbreviated) -> String {
    let first = start.vectaFormatted(date: date, time: .shortened)
    guard duration.isFinite, duration >= 1 else { return first }
    let end = start.addingTimeInterval(duration)
    let last = Calendar.current.isDate(start, inSameDayAs: end) ? end.vectaFormatted(date: .omitted, time: .shortened) : end.vectaFormatted(date: date, time: .shortened)
    return first + " – " + last
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

