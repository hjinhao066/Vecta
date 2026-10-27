import AppKit
import SwiftUI

struct NativeDailyReflectionScreen: View {
    @ObservedObject var run: ReflectionRunController
    @StateObject private var store = DailyReflectionStore()
    @State private var selectedID: String? = Self.verificationArgument("--verify-reflection-day")
    @State private var hoveredID: String?

    private static func verificationArgument(_ name: String) -> String? {
        #if VECTA_DEVELOPMENT
        if let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) { return CommandLine.arguments[index + 1] }
        #endif
        return nil
    }

    private var selected: DailyReflectionDay? { store.days.first { $0.id == selectedID } ?? store.days.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ScreenTitle(title: VL.text("Ежедневная рефлексия"))
                if store.folder != nil {
                    Button { reveal() } label: { Image(systemName: "folder").font(.system(size: 14)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain).foregroundColor(Ink.secondary).background(Ink.elevated).cornerRadius(7)
                        .help(VL.text("Показать файл в Finder")).accessibilityLabel(VL.text("Показать файл в Finder"))
                }
                Spacer(minLength: 12)
                if let display = run.display { ReflectionRunStatus(display: display) }
                Button(VL.text("Начать рефлексию")) { run.start() }
                    .buttonStyle(QuietButton(primary: true)).disabled(run.display?.busy == true)
                    .opacity(run.display?.busy == true ? 0.55 : 1).fixedSize()
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
                        if let day = selected { reader(day, compact: compact) } else { Spacer() }
                    }
                }.overlay(alignment: .top) { Rectangle().fill(Ink.border).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: run.display) { value in if value?.tone == .done { store.refresh(force: true) } }
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

    private func row(_ day: DailyReflectionDay) -> some View {
        let isSelected = day.id == selected?.id
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

    private func reader(_ day: DailyReflectionDay, compact: Bool) -> some View {
        ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(VL.locale)))
                    .font(.system(size: compact ? 19 : 22, weight: .semibold)).foregroundColor(Ink.text).textSelection(.enabled)
                    .padding(.bottom, 6)
                ReflectionMarkdownView(blocks: day.blocks, base: day.file.deletingLastPathComponent())
            }.frame(maxWidth: 960, alignment: .leading).padding(.horizontal, compact ? 20 : 36).padding(.top, 22).padding(.bottom, 48)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block).padding(.top, index == 0 ? 8 : spacing(before: block)).id(index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Ink.link)
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url.absoluteURL) ? .handled : .systemAction
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in listRow(item) }
            }
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

    private func listRow(_ item: ReflectionListItem) -> some View {
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
    @State private var dim = false

    private var color: Color {
        switch display.tone { case .working: return Ink.warning; case .done: return Ink.success; case .failed: return Ink.error }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
                .opacity(display.busy && dim && !reduceMotion ? 0.35 : 1)
                .animation(display.busy && !reduceMotion ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: dim)
            Text(display.text).font(.system(size: 12.5)).foregroundColor(display.tone == .failed ? Ink.error : Ink.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .help(display.text).accessibilityElement(children: .combine)
        .onAppear { dim = display.busy }
        .onChange(of: display.busy) { busy in dim = busy }
    }
}
