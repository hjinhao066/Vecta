import AppKit
import AVFoundation
import SwiftUI

// The pieces of the Daily Reflection page that go beyond plain Markdown: the coloured time allocation, todos you can
// tick, the all-days todo list and the whole-day transcript with playback.

private extension Color {
    init(hexString: String) {
        let digits = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(digits, radix: 16) ?? 0x8E97A8)
    }
}

extension ReflectionListItem {
    /// Identity for animation: the review's own id, else the words.
    var key: String { id ?? "text:" + text }
}

func reflectionHoursLabel(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value)) h" : String(format: "%.1f h", value)
}

// MARK: - Time allocation

struct ReflectionHoursView: View {
    let hours: ReflectionHours

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geometry in
                let gap: CGFloat = 3
                let room = max(1, geometry.size.width - gap * CGFloat(max(hours.entries.count - 1, 0)))
                HStack(spacing: gap) {
                    ForEach(hours.entries) { entry in
                        RoundedRectangle(cornerRadius: 5).fill(Color(hexString: entry.hex))
                            .frame(width: max(5, room * CGFloat(entry.hours / max(hours.total, 0.01))))
                            .help("\(entry.name) · \(reflectionHoursLabel(entry.hours))")
                    }
                }
            }.frame(height: 30).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(spacing: 0) {
                ForEach(hours.entries) { entry in row(entry) }
            }
            if let covered = hours.covered {
                Text(VL.text("Covers the time the recorder was on or you were at the computer: ") + reflectionHoursLabel(covered) + VL.text(". A rough estimate."))
                    .font(.system(size: 11.5)).foregroundColor(Ink.muted)
            }
        }
        .padding(16)
        .background(Ink.surface).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.border))
    }

    private func row(_ entry: ReflectionHours.Entry) -> some View {
        let widest = max(hours.entries.map(\.hours).max() ?? 1, 0.01)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color(hexString: entry.hex)).frame(width: 9, height: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            Text(entry.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Ink.text).frame(width: 92, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.border.opacity(0.6))
                Capsule().fill(Color(hexString: entry.hex)).frame(width: 84 * CGFloat(entry.hours / widest))
            }.frame(width: 84, height: 6)
            Text(reflectionHoursLabel(entry.hours)).font(.system(size: 13)).monospacedDigit().foregroundColor(Ink.text).frame(width: 46, alignment: .trailing)
            Text(entry.note).font(.system(size: 12.5)).foregroundColor(Ink.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(.vertical, 7)
    }
}

// MARK: - Todos

/// One todo: a tick that moves it to the bottom of its list, the words (links jump into the transcript), struck out when done.
struct ReflectionTaskLine: View {
    let item: ReflectionListItem
    let base: URL?
    var dayTag: String? = nil
    @ObservedObject private var checks = ReflectionChecks.shared

    init(item: ReflectionListItem, base: URL?, dayTag: String? = nil) {
        self.item = item; self.base = base; self.dayTag = dayTag
    }

    private var done: Bool { checks.isDone(item.id ?? "", fallback: item.task ?? false) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button {
                guard let id = item.id else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { checks.set(id, done: !done) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
                    .foregroundColor(done ? Ink.accent : Ink.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(item.id == nil)
            .accessibilityLabel(done ? VL.text("Done. Tap to reopen") : VL.text("Not done. Tap to mark done"))
            if let dayTag {
                Text(dayTag).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Ink.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Ink.elevated).cornerRadius(5)
            }
            Text(styled).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.opacity(done ? 0.62 : 1)
    }

    private var styled: AttributedString {
        var text = ReflectionMarkdown.inline(item.text, base: base)
        if done { text.strikethroughStyle = .single; text.foregroundColor = Ink.muted } else { text.foregroundColor = Ink.text }
        return text
    }
}

/// Every open todo from every day's 待办 and 明天要做 sections, newest day first. Ticked ones sink to the bottom;
/// open ones older than a month fold away.
struct ReflectionTodoBoard: View {
    let days: [DailyReflectionDay]
    @ObservedObject private var checks = ReflectionChecks.shared
    @State private var showOld = false

    struct Entry: Identifiable {
        let day: DailyReflectionDay
        let item: ReflectionListItem
        var id: String { item.key }
    }

    static func entries(in days: [DailyReflectionDay]) -> [Entry] {
        var found: [Entry] = []
        for day in days {
            var section = ""
            for block in day.blocks {
                if case .heading(_, let title) = block { section = title }
                if case .list(let items) = block, section == "待办" || section == "明天要做" {
                    found += items.filter { $0.id != nil && $0.task != nil }.map { Entry(day: day, item: $0) }
                }
            }
        }
        return found
    }

    static func openCount(in days: [DailyReflectionDay], checks: ReflectionChecks) -> Int {
        entries(in: days).filter { !checks.isDone($0.item.id ?? "", fallback: $0.item.task ?? false) }.count
    }

    private func state(_ entry: Entry) -> Bool { checks.isDone(entry.item.id ?? "", fallback: entry.item.task ?? false) }

    var body: some View {
        let all = Self.entries(in: days)
        let open = all.filter { !state($0) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let recent = open.filter { $0.day.date >= cutoff }, old = open.filter { $0.day.date < cutoff }
        let done = Array(all.filter(state).sorted {
            (checks.marks[$0.item.id ?? ""]?.at ?? .distantPast) < (checks.marks[$1.item.id ?? ""]?.at ?? .distantPast)
        }.suffix(30))
        let order = (recent + old + done).map { $0.id + (state($0) ? ":done" : ":open") }
        return VStack(alignment: .leading, spacing: 14) {
            if open.isEmpty && done.isEmpty {
                Text(VL.text("Nothing to do. New todos from the daily review appear here.")).foregroundColor(Ink.secondary)
            }
            VStack(alignment: .leading, spacing: 11) {
                ForEach(recent + Array(showOld ? old : [])) { line($0) }
                if !old.isEmpty {
                    Button(showOld ? VL.text("Hide older than 30 days") : VL.text("Older than 30 days") + " (\(old.count))") {
                        withAnimation(.easeInOut(duration: 0.2)) { showOld.toggle() }
                    }.buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundColor(Ink.link)
                }
                ForEach(done) { line($0) }
            }.animation(.spring(response: 0.45, dampingFraction: 0.82), value: order)
        }
    }

    private func line(_ entry: Entry) -> some View {
        ReflectionTaskLine(item: entry.item, base: entry.day.file.deletingLastPathComponent(),
                           dayTag: entry.day.date.formatted(.dateTime.month(.abbreviated).day().locale(VL.locale)))
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Playback

/// Plays the audio behind a transcript sentence from where it was said.
@MainActor final class ReflectionAudioPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var activeKey: String?
    @Published private(set) var current: ReflectionTranscript.Segment?
    private var transcript: ReflectionTranscript?
    private var player: AVAudioPlayer?
    private var loadedPath: String?
    private var timer: Timer?
    private var bySha: [String: [ReflectionTranscript.Segment]] = [:]

    func load(_ transcript: ReflectionTranscript) {
        self.transcript = transcript
        bySha = Dictionary(grouping: transcript.segments, by: \.sha).mapValues { $0.sorted { $0.offset < $1.offset } }
    }

    /// Seconds into the file, and the wall-clock time of that moment, for the player bar.
    var clock: (position: Double, wall: String)? {
        guard let player, let segment = current, let recording = transcript?.recordings[segment.sha],
              let start = ISO8601DateFormatter().date(from: recording.start) else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        return (player.currentTime, formatter.string(from: start.addingTimeInterval(player.currentTime)))
    }

    func play(_ segment: ReflectionTranscript.Segment) {
        guard let path = transcript?.recordings[segment.sha]?.audio, FileManager.default.fileExists(atPath: path) else {
            current = nil; playing = false; return
        }
        do {
            if loadedPath != path { player?.stop(); player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)); loadedPath = path }
            player?.currentTime = max(0, segment.offset - 0.2)
            player?.play()
            current = segment; activeKey = segment.id; playing = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        } catch { current = nil; playing = false }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil; loadedPath = nil
        playing = false; activeKey = nil; current = nil
    }

    private func tick() {
        guard let player, let sha = current?.sha else { return }
        if !player.isPlaying && playing && player.currentTime == 0 { playing = false; return }  // reached the end
        playing = player.isPlaying
        let position = player.currentTime, list = bySha[sha] ?? []
        var low = 0, high = list.count
        while low < high { let middle = (low + high) / 2; if list[middle].offset <= position { low = middle + 1 } else { high = middle } }
        let now = low > 0 ? list[low - 1] : nil
        if now?.id != activeKey { activeKey = now?.id }
    }
}

struct ReflectionPlayerBar: View {
    @ObservedObject var player: ReflectionAudioPlayer

    var body: some View {
        if player.current != nil {
            HStack(spacing: 12) {
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundColor(Ink.onAccent).background(Ink.accent).clipShape(Circle())
                    .accessibilityLabel(player.playing ? VL.text("Pause") : VL.text("Play"))
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(player.clock?.wall ?? "").font(.system(size: 13)).monospacedDigit().foregroundColor(Ink.text)
                }
                Spacer(minLength: 0)
                Button { player.stop() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundColor(Ink.secondary).accessibilityLabel(VL.text("Stop playback"))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Ink.elevated).cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.border))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
    }
}

// MARK: - Whole-day transcript

struct ReflectionJumpRequest: Equatable, Identifiable {
    let id = UUID()
    let day: String
    let time: String
}

struct ReflectionTranscriptPane: View {
    let transcript: ReflectionTranscript
    @Binding var request: ReflectionJumpRequest?
    @ObservedObject var player: ReflectionAudioPlayer
    @State private var flash: String?

    private enum Row: Identifiable {
        case gap(String, Int)
        case line(ReflectionTranscript.Segment)
        var id: String {
            switch self { case .gap(let key, _): return "gap-" + key; case .line(let segment): return segment.id }
        }
    }

    private static func seconds(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : 0
    }

    private var rows: [Row] {
        var out: [Row] = [], last: Int?
        for segment in transcript.segments {
            let at = Self.seconds(segment.t)
            if let previous = last {
                let gap = (at - previous + 86400) % 86400
                if gap > 600 { out.append(.gap(segment.id, gap / 60)) }
            }
            out.append(.line(segment)); last = at
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        switch row {
                        case .gap(_, let minutes):
                            Text(VL.text("No speech for ") + "\(minutes)" + VL.text(" min")).font(.system(size: 11.5)).foregroundColor(Ink.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        case .line(let segment):
                            line(segment)
                        }
                    }
                }.padding(.bottom, 70)
            }
            .task(id: request?.id) {
                guard let asked = request, asked.day == transcript.day, let target = transcript.segment(at: asked.time) else { return }
                flash = target.id
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .center) }
                player.play(target)
                request = nil
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if flash == target.id { withAnimation { flash = nil } }
            }
        }.overlay(alignment: .bottom) { ReflectionPlayerBar(player: player).padding(.bottom, 12).padding(.horizontal, 4) }
    }

    private func line(_ segment: ReflectionTranscript.Segment) -> some View {
        let active = player.activeKey == segment.id, flashed = flash == segment.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(segment.t) { player.play(segment) }
                .buttonStyle(.plain).font(.system(size: 11.5)).monospacedDigit().foregroundColor(Ink.link).frame(width: 62, alignment: .leading)
                .accessibilityLabel(VL.text("Play from ") + segment.t)
            Text(speaker(segment.speaker)).font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(segment.speaker == "me" ? Ink.accent : Ink.muted).frame(width: 38, alignment: .leading)
            Text(segment.text).font(.system(size: 14)).lineSpacing(4).foregroundColor(Ink.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background((active || flashed) ? Ink.selection : Color.clear).cornerRadius(7)
        .id(segment.id)
    }

    private func speaker(_ value: String?) -> String {
        switch value { case "me": return VL.text("Me"); case "other": return VL.text("Other"); default: return value == nil ? "" : "?" }
    }
}
