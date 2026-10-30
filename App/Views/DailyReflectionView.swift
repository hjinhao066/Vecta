import AppKit
import SwiftUI

struct NativeDailyReflectionScreen: View {
    @ObservedObject var run: ReflectionRunController
    @StateObject private var store = DailyReflectionStore()
    @State private var selectedID: String? = Self.verificationArgument("--verify-reflection-day")
    @State private var hoveredID: String?
    @State private var mode: ReflectionMode = .review
    @State private var transcript: ReflectionTranscript?
    @State private var request: ReflectionJumpRequest?
    @StateObject private var player = ReflectionAudioPlayer()
    @ObservedObject private var checks = ReflectionChecks.shared
    private static let boardID = "__todos__"
    enum ReflectionMode: Hashable { case review, transcript }

    private static func verificationArgument(_ name: String) -> String? {
        #if VECTA_DEVELOPMENT
        if let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) { return CommandLine.arguments[index + 1] }
        #endif
        return nil
    }

    private var showingBoard: Bool { selectedID == Self.boardID }
    private var selected: DailyReflectionDay? { store.days.first { $0.id == selectedID } ?? store.days.first }

    /// A `vecta://reflection?day=…&t=HH:MM:SS` link: open that day's transcript at that sentence and play it.
    private func jump(day: String, time: String) {
        guard store.days.contains(where: { $0.id == day }) else { return }
        request = ReflectionJumpRequest(day: day, time: time)
        mode = .transcript
        selectedID = day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The step line sits beside the button; when the row is too narrow for it, it moves under the title.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ScreenTitle(title: VL.text("Ежедневная рефлексия")).fixedSize()
                    Spacer(minLength: 0)
                    if let display = run.display { ReflectionRunStatus(display: display).fixedSize() }
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { ScreenTitle(title: VL.text("Ежедневная рефлексия")); actions }
                    if let display = run.display { ReflectionRunStatus(display: display) }
                }
            }.padding(.horizontal, 28).padding(.top, 28)
            if let problem = store.problem { message(problem, action: VL.text("Выбрать папку…")) }
            else if store.folder == nil { message(VL.text("Папка с ежедневными рефлексиями не найдена. Выберите папку с файлами вида 2026-10.md."), action: VL.text("Выбрать папку…")) }
            else if store.loaded && store.days.isEmpty { message(VL.text("В папке пока нет записей. Они появятся здесь сами, как только AI допишет отчёт за день."), action: nil) }
            else if !store.loaded { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(VL.text("Читаем рефлексии…")).foregroundColor(Ink.secondary) }.padding(.horizontal, 28) }
            else {
                // Narrow windows give the list less room and the text tighter margins.
                GeometryReader { geometry in
                    let compact = geometry.size.width < 760
                    HStack(spacing: 0) {
                        dayList.frame(width: compact ? 200 : 252)
                        Rectangle().fill(Ink.border).frame(width: 1)
                        if showingBoard { board(compact: compact) }
                        else if let day = selected { reader(day, compact: compact) } else { Spacer() }
                    }
                }.overlay(alignment: .top) { Rectangle().fill(Ink.border).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.start(); checks.reload() }
        .onDisappear { store.stop(); player.stop() }
        .onChange(of: selectedID) { value in
            if request?.day != value { mode = .review; player.stop() }
        }
        .onChange(of: run.display) { value in if value?.tone == .done { store.refresh(force: true) } }
    }

    @ViewBuilder private var actions: some View {
        Button(VL.text("Начать рефлексию")) { run.start() }
            .buttonStyle(QuietButton(primary: true)).disabled(run.display?.busy == true)
            .opacity(run.display?.busy == true ? 0.55 : 1).fixedSize()
        if store.folder != nil {
            Button { reveal() } label: { Image(systemName: "folder").font(.system(size: 14)).frame(width: 30, height: 30) }
                .buttonStyle(.plain).foregroundColor(Ink.secondary).background(Ink.elevated).cornerRadius(7)
                .help(VL.text("Показать файл в Finder")).accessibilityLabel(VL.text("Показать файл в Finder"))
        }
    }

    private func message(_ text: String, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text).foregroundColor(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action, action: chooseFolder).buttonStyle(QuietButton(primary: true)) }
        }.frame(maxWidth: 560, alignment: .leading).padding(.horizontal, 28)
    }

    private var months: [(String, [DailyReflectionDay])] {
        var order: [String] = []; var groups: [String: [DailyReflectionDay]] = [:]
        for day in store.days {
            let key = String(day.id.prefix(7))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(day)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var dayList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                boardRow
                ForEach(months, id: \.0) { month, days in
                    Section {
                        ForEach(days) { day in row(day) }
                    } header: {
                        Text(days.first.map { $0.date.formatted(.dateTime.month(.wide).year().locale(VL.locale)) } ?? month)
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(Ink.muted)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading).background(Ink.canvas)
                    }
                }
            }.padding(.horizontal, 10).padding(.bottom, 16)
        }
    }

    private var boardRow: some View {
        let open = ReflectionTodoBoard.openCount(in: store.days, checks: checks)
        let isSelected = showingBoard
        return Button { selectedID = Self.boardID } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5).fill(isSelected ? Ink.accent : Color.clear).frame(width: 3)
                Image(systemName: "checklist").font(.system(size: 13)).foregroundColor(Ink.accent)
                Text(VL.text("To do")).font(.system(size: 13, weight: .semibold)).foregroundColor(Ink.text)
                Spacer(minLength: 0)
                if open > 0 {
                    Text("\(open)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(Ink.onAccent)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Ink.accent).clipShape(Capsule())
                }
            }.padding(.vertical, 10).padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(isSelected ? Ink.selection : Color.clear).cornerRadius(7)
        }.buttonStyle(.plain).padding(.top, 8)
            .accessibilityLabel(VL.text("To do")).accessibilityValue("\(open)")
    }

    private func row(_ day: DailyReflectionDay) -> some View {
        let isSelected = !showingBoard && day.id == selected?.id
        return Button { selectedID = day.id } label: {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5).fill(isSelected ? Ink.accent : Color.clear).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(day.date.formatted(.dateTime.month(.abbreviated).day().locale(VL.locale))).font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Ink.text)
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated).locale(VL.locale))).font(.system(size: 11)).foregroundColor(Ink.muted)
                        Spacer(minLength: 0)
                        if Calendar.current.isDateInToday(day.date) { Text(VL.text("Сегодня")).font(.system(size: 10, weight: .semibold)).foregroundColor(Ink.accent) }
                    }
                    if !day.summary.isEmpty {
                        Text(day.summary).font(.system(size: 11.5)).foregroundColor(Ink.secondary).lineLimit(2).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.vertical, 9).padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(isSelected ? Ink.selection : (hoveredID == day.id ? Ink.hover : Color.clear)).cornerRadius(7)
        }.buttonStyle(.plain)
            .onHover { inside in hoveredID = inside ? day.id : (hoveredID == day.id ? nil : hoveredID) }
            .help(day.summary)
            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(isSelected ? VL.text("Выбрано") : VL.text("Не выбрано"))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func board(compact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(VL.text("To do")).font(.system(size: compact ? 19 : 22, weight: .semibold)).foregroundColor(Ink.text).padding(.bottom, 14)
                ReflectionTodoBoard(days: store.days)
            }.frame(maxWidth: 960, alignment: .leading).padding(.horizontal, compact ? 20 : 36).padding(.top, 22).padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = Self.reflectionLink(url) else { return NSWorkspace.shared.open(url.absoluteURL) ? .handled : .systemAction }
            jump(day: link.day, time: link.time)
            return .handled
        })
    }

    static func reflectionLink(_ url: URL) -> (day: String, time: String)? {
        guard url.scheme == "vecta", url.host == "reflection",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let day = items.first(where: { $0.name == "day" })?.value, let time = items.first(where: { $0.name == "t" })?.value else { return nil }
        return (day, time)
    }

    private func reader(_ day: DailyReflectionDay, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(VL.locale)))
                    .font(.system(size: compact ? 19 : 22, weight: .semibold)).foregroundColor(Ink.text).textSelection(.enabled)
                Spacer(minLength: 0)
                if transcript?.day == day.id {
                    Picker("", selection: $mode) {
                        Text(VL.text("Review")).tag(ReflectionMode.review)
                        Text(VL.text("Full transcript")).tag(ReflectionMode.transcript)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                }
            }.padding(.horizontal, compact ? 20 : 36).padding(.top, 22).padding(.bottom, 8)
            if mode == .transcript, let transcript, transcript.day == day.id {
                ReflectionTranscriptPane(transcript: transcript, request: $request, player: player)
                    .padding(.horizontal, compact ? 12 : 28)
            } else {
                reviewScroll(day, compact: compact)
            }
        }
        .task(id: day.id) {
            let id = day.id
            let loaded = await Task.detached(priority: .userInitiated) { ReflectionTranscript.load(day: id) }.value
            transcript = loaded
            if let loaded { player.load(loaded) }
        }
    }

    private func reviewScroll(_ day: DailyReflectionDay, compact: Bool) -> some View {
        ScrollViewReader { proxy in ScrollView {
            ReflectionMarkdownView(blocks: day.blocks, base: day.file.deletingLastPathComponent(), jump: jump)
                .frame(maxWidth: 960, alignment: .leading).padding(.horizontal, compact ? 20 : 36).padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear {
            let target = Self.verificationArgument("--verify-reflection-block")
            let table = day.blocks.firstIndex { if case .table = $0 { return true } else { return false } }
            if let block = target == "table" ? table : target.flatMap(Int.init) {
                DispatchQueue.main.async { proxy.scrollTo(block, anchor: .top) }
            }
        } }.id(day.id)
    }

    private func reveal() {
        if let file = selected?.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else if let folder = store.folder { NSWorkspace.shared.open(folder) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = VL.text("Выбрать")
        panel.directoryURL = store.folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        if panel.runModal() == .OK, let url = panel.url { store.choose(url) }
    }
}

struct ReflectionMarkdownView: View {
    let blocks: [ReflectionBlock]
    let base: URL?
    var jump: ((String, String) -> Void)? = nil
    @ObservedObject private var checks = ReflectionChecks.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block).padding(.top, index == 0 ? 8 : spacing(before: block)).id(index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Ink.link)
        .environment(\.openURL, OpenURLAction { url in
            if let link = NativeDailyReflectionScreen.reflectionLink(url) {
                guard let jump else { return .handled }
                jump(link.day, link.time)
                return .handled
            }
            return NSWorkspace.shared.open(url.absoluteURL) ? .handled : .systemAction
        })
    }

    private func spacing(before block: ReflectionBlock) -> CGFloat {
        switch block {
        case .heading(let level, _): return level <= 3 ? 26 : 18
        case .sourceBreak, .rule: return 22
        default: return 10
        }
    }

    private func text(_ source: String) -> Text { Text(ReflectionMarkdown.inline(source, base: base)) }

    @ViewBuilder private func view(_ block: ReflectionBlock) -> some View {
        switch block {
        case .heading(let level, let title):
            heading(level, title)
        case .paragraph(let value):
            text(value).font(.system(size: 14)).lineSpacing(5).foregroundColor(Ink.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            let shown = checks.ordered(items)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.element.key) { _, item in listRow(item) }
            }.animation(.spring(response: 0.45, dampingFraction: 0.82), value: shown.map(\.key))
        case .hours(let hours):
            ReflectionHoursView(hours: hours)
        case .table(let header, let rows):
            table(header, rows)
        case .code(let value):
            Text(value).font(.system(size: 12.5, design: .monospaced)).foregroundColor(Ink.code).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Ink.codeBg).cornerRadius(7)
        case .quote(let value):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Ink.quoteBar).frame(width: 3)
                text(value).font(.system(size: 14)).lineSpacing(5).foregroundColor(Ink.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Ink.border).frame(height: 1)
        case .sourceBreak:
            Rectangle().fill(Ink.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder private func heading(_ level: Int, _ title: String) -> some View {
        switch level {
        case 1, 2: text(title).font(.system(size: 20, weight: .semibold)).foregroundColor(Ink.heading)
        case 3: text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(Ink.heading)
        case 4: text(title).font(.system(size: 14.5, weight: .semibold)).foregroundColor(Ink.subheading)
        default: text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Ink.secondary)
        }
    }

    @ViewBuilder private func listRow(_ item: ReflectionListItem) -> some View {
        if item.id != nil, item.task != nil {
            ReflectionTaskLine(item: item, base: base).padding(.leading, CGFloat(item.level) * 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            plainRow(item)
        }
    }

    private func plainRow(_ item: ReflectionListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let done = item.task {
                    Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: 13)).foregroundColor(done ? Ink.accent : Ink.muted)
                        .accessibilityLabel(done ? VL.text("Выполнено") : VL.text("Не выполнено"))
                } else if let marker = item.marker {
                    Text(marker).font(.system(size: 13.5)).monospacedDigit().foregroundColor(Ink.muted)
                } else {
                    Circle().fill(item.level == 0 ? Ink.accent : Ink.muted).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                }
            }.frame(minWidth: 14, alignment: .center)
            text(item.text).font(.system(size: 14)).lineSpacing(5).foregroundColor(Ink.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.leading, CGFloat(item.level) * 20)
    }

    /// Fits the width when the columns can keep whole words; otherwise scrolls sideways in its own frame.
    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        let columns = ReflectionTableColumns.columns(header: header, rows: rows)
        let minimum = columns.minimums.reduce(0, +)
        return ViewThatFits(in: .horizontal) {
            tableBody(header, rows, columns)
            ScrollView(.horizontal) { tableBody(header, rows, columns).frame(width: minimum) }
        }
    }

    private func tableBody(_ header: [String], _ rows: [[String]], _ columns: (weights: [CGFloat], minimums: [CGFloat])) -> some View {
        VStack(spacing: 0) {
            ReflectionTableColumns(columns: columns) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    text(cell).font(.system(size: 13, weight: .semibold)).foregroundColor(Ink.tableHead)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 8)
                }
            }.background(Ink.tableHeadBg)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                ReflectionTableColumns(columns: columns) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        text(cell).font(.system(size: 13)).lineSpacing(3).foregroundColor(Ink.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 7)
                    }
                }.background(index % 2 == 1 ? Ink.rowAlt : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.border))
    }
}

/// One line beside Start reflection: a coloured dot (yellow working, green done, red failed) and the step.
struct ReflectionRunStatus: View {
    let display: ReflectionRunDisplay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch display.tone { case .working: return Ink.warning; case .done: return Ink.success; case .failed: return Ink.error }
    }

    var body: some View {
        HStack(spacing: 7) {
            // Breathes by size, not by fading, so the colour keeps its contrast. Driven by the clock rather than an
            // implicit animation, so a layout change never sends the dot sliding across the text.
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !display.busy || reduceMotion)) { context in
                let phase = display.busy && !reduceMotion ? (sin(context.date.timeIntervalSinceReferenceDate * 2.6) + 1) / 2 : 1
                Circle().fill(color).frame(width: 8, height: 8).scaleEffect(0.6 + 0.4 * phase)
            }.frame(width: 8, height: 8)
            Text(display.text).font(.system(size: 12.5)).foregroundColor(display.tone == .failed ? Ink.error : Ink.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .help(display.text).accessibilityElement(children: .combine)
    }
}
