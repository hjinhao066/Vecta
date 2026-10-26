import AppKit
import SwiftUI

/// One day of the personal daily review: everything under its `## YYYY-MM-DD` heading in the
/// monthly file, with every source block (recording review, one-thing review, Hermes reflection).
struct DailyReflectionDay: Identifiable, Equatable {
    let id: String
    let date: Date
    let markdown: String
    let summary: String
    let file: URL
    let blocks: [ReflectionBlock]
}

/// Reads the monthly review files (`YYYY-MM.md`). Read-only: nothing here writes or moves files.
enum DailyReflectionSource {
    static let folderKey = "Vecta.dailyReflection.folder"
    private static let dayHeading = try! NSRegularExpression(pattern: #"^## (\d{4}-\d{2}-\d{2})\b"#)
    private static let monthFile = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}\.md$"#)

    static func folder(preferences: UserDefaults = VL.preferences) -> URL? {
        #if VECTA_DEVELOPMENT
        if let index = CommandLine.arguments.firstIndex(of: "--verify-reflection-folder"), CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        #endif
        if let path = preferences.string(forKey: folderKey), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return detected()
    }

    /// The shared review folder on Google Drive for desktop, whichever account it is mounted under.
    static func detected(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where entry.lastPathComponent.hasPrefix("GoogleDrive-") {
            let candidate = entry.appendingPathComponent("My Drive/[01]AI/个人复盘/daily", isDirectory: true)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), directory.boolValue { return candidate }
        }
        return nil
    }

    static func monthFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { name in monthFile.firstMatch(in: name.lastPathComponent, range: NSRange(name.lastPathComponent.startIndex..., in: name.lastPathComponent)) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Changes whenever a monthly file is added, removed, resized or rewritten.
    static func signature(of folder: URL) -> String {
        guard let files = try? monthFiles(in: folder) else { return "unreadable" }
        return files.map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(file.lastPathComponent):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    static func load(folder: URL) throws -> [DailyReflectionDay] {
        var sections: [String: (text: String, file: URL)] = [:]
        for file in try monthFiles(in: folder) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (id, body) in split(text) {
                if let existing = sections[id] { sections[id] = (existing.text + "\n\n" + body, existing.file) }
                else { sections[id] = (body, file) }
            }
        }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
        return sections.compactMap { id, value in
            guard let date = parser.date(from: id) else { return nil }
            return DailyReflectionDay(id: id, date: date, markdown: value.text, summary: summary(value.text), file: value.file, blocks: ReflectionMarkdown.parse(value.text))
        }.sorted { $0.id > $1.id }
    }

    /// Day sections in file order: the `## YYYY-MM-DD …` line starts one, the next `## ` line ends it.
    static func split(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var current: String?
        var lines: [String] = []
        func flush() {
            if let current { result.append((current, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
            lines = []
        }
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenced.toggle() }
            if !fenced, line.hasPrefix("## ") {
                flush()
                let range = NSRange(line.startIndex..., in: line)
                if let match = dayHeading.firstMatch(in: line, range: range), let day = Range(match.range(at: 1), in: line) { current = String(line[day]) }
                else { current = nil }
                continue
            }
            if current != nil { lines.append(line) }
        }
        flush()
        return result
    }

    /// The one-line summary the recording review writes (`#### 一句话`), else the first prose line.
    static func summary(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func clean(_ line: String) -> String {
            ReflectionMarkdown.plain(line.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression))
        }
        // Recording reviews open with 一句话; Hermes reflections carry a 今日判断 section.
        for label in ["一句话", "今日判断"] {
            if let index = lines.firstIndex(where: { ($0.hasPrefix("#") || $0.hasPrefix("**")) && $0.contains(label) }),
               let line = lines[(index + 1)...].first(where: { !$0.isEmpty }), !line.hasPrefix("#") {
                return clean(line)
            }
        }
        let prose = lines.first { line in
            !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("<!--") && !line.hasPrefix("|") && !line.hasPrefix(">") && !line.hasPrefix("```") && !line.hasPrefix("---")
                && !line.hasPrefix("来源") && !(line.hasPrefix("**") && (line.hasSuffix("**") || line.hasSuffix("**：") || line.hasSuffix("**:")))
        }
        return prose.map(clean) ?? ""
    }
}

@MainActor final class DailyReflectionStore: ObservableObject {
    @Published private(set) var days: [DailyReflectionDay] = []
    @Published private(set) var folder: URL?
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    private var signature: String?
    private var loading = false
    private var timer: Timer?

    func start() {
        refresh(force: true)
        timer?.invalidate()
        // Drive writes do not always raise file events, so look at sizes and dates every few seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func choose(_ url: URL) {
        VL.preferences.set(url.path, forKey: DailyReflectionSource.folderKey)
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard !loading else { return }
        let folder = DailyReflectionSource.folder()
        if folder != self.folder { self.folder = folder; signature = nil }
        guard let folder else { days = []; problem = nil; loaded = true; return }
        let previous = force ? nil : signature
        loading = true
        Task.detached(priority: .utility) {
            let current = DailyReflectionSource.signature(of: folder)
            if current == previous { await MainActor.run { self.loading = false }; return }
            let result = Result { try DailyReflectionSource.load(folder: folder) }
            await MainActor.run {
                self.loading = false
                self.signature = current
                self.loaded = true
                switch result {
                case .success(let days): self.days = days; self.problem = nil
                case .failure: self.problem = VL.text("Не удалось прочитать папку с рефлексиями. Проверьте, что Google Drive подключён и Vecta разрешён доступ к нему.")
                }
            }
        }
    }
}

// MARK: - Markdown

struct ReflectionListItem: Equatable {
    let level: Int
    let marker: String?   // "1." for ordered items, nil for bullets
    let task: Bool?       // nil: not a task; true: done
    var text: String
}

enum ReflectionBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list([ReflectionListItem])
    case table([String], [[String]])
    case code(String)
    case quote(String)
    case rule
    case sourceBreak
}

/// A small block parser for the review files: headings, paragraphs, nested and task lists,
/// tables, code, quotes and rules. Inline styling and links go through Foundation's Markdown.
enum ReflectionMarkdown {
    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])\s+(.*)$"#)
    private static let taskBox = try! NSRegularExpression(pattern: #"^\[([ xX])\]\s+(.*)$"#)
    private static let separator = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#)

    static func parse(_ text: String) -> [ReflectionBlock] {
        var blocks: [ReflectionBlock] = []
        var paragraph: [String] = [], quote: [String] = [], items: [ReflectionListItem] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(join(paragraph))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(join(quote))); quote = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
        }
        var index = 0
        while index < lines.count {
            let raw = lines[index], line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("```") {
                flush()
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("<!--") {
                flush()
                // Source blocks (one-thing, plaud-recording, hermes-…) start with a begin marker.
                if line.contains(":begin"), !blocks.isEmpty, blocks.last != .sourceBreak { blocks.append(.sourceBreak) }
                while !lines[index - 1].contains("-->"), index < lines.count { index += 1 }
                continue
            }
            if line.isEmpty { flush(); continue }
            if let level = headingLevel(line) {
                flush()
                blocks.append(.heading(level, String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("|"), index < lines.count, matches(separator, lines[index]) {
                flush()
                let header = cells(line)
                index += 1
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[index].trimmingCharacters(in: .whitespaces))
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(max(header.count, 1)))); index += 1
                }
                blocks.append(.table(header, rows))
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty || !items.isEmpty { flush() }
                quote.append(String(line.drop(while: { $0 == ">" })).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let match = listItem.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let indentRange = Range(match.range(at: 1), in: raw), let markerRange = Range(match.range(at: 2), in: raw), let bodyRange = Range(match.range(at: 3), in: raw) {
                if !paragraph.isEmpty || !quote.isEmpty { let kept = items; items = []; flush(); items = kept }
                let indent = raw[indentRange].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let marker = String(raw[markerRange])
                var body = String(raw[bodyRange]), task: Bool?
                if let box = taskBox.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                   let state = Range(box.range(at: 1), in: body), let rest = Range(box.range(at: 2), in: body) {
                    task = body[state] != " "; body = String(body[rest])
                }
                items.append(ReflectionListItem(level: min(indent / 2, 6), marker: marker.first?.isNumber == true ? marker : nil, task: task, text: body))
                continue
            }
            if !items.isEmpty, raw.first == " " || raw.first == "\t" {
                items[items.count - 1].text += (needsSpace(items[items.count - 1].text, line) ? " " : "") + line
                continue
            }
            if !items.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.count == hashes || line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body.removeLast() }
        var result: [String] = [], current = "", escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Soft line breaks: a space between Latin words, nothing between Chinese characters.
    static func join(_ lines: [String]) -> String {
        lines.dropFirst().reduce(lines.first ?? "") { $0 + (needsSpace($0, $1) ? " " : "") + $1 }
    }
    private static func needsSpace(_ left: String, _ right: String) -> Bool {
        guard let a = left.last, let b = right.first else { return false }
        return !(isWide(a) && isWide(b))
    }
    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x2E80...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) } ?? false
    }

    static func plain(_ text: String) -> String {
        let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))
        return parsed.map { String($0.characters) } ?? text
    }

    static func inline(_ text: String, base: URL?) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible), baseURL: base)) ?? AttributedString(text)
        for run in value.runs {
            if run.link != nil {
                value[run.range].foregroundColor = Ink.link
                value[run.range].underlineStyle = Text.LineStyle.single
            } else if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { value[run.range].foregroundColor = Ink.code; value[run.range].backgroundColor = Ink.codeBg }
                else if intent.contains(.stronglyEmphasized) { value[run.range].foregroundColor = Ink.strong }
            }
        }
        return value
    }
}

/// One table row: columns share the width by how much text each column holds, every cell top-aligned.
struct ReflectionTableColumns: Layout {
    let weights: [CGFloat]

    let minimums: [CGFloat]

    init(columns: (weights: [CGFloat], minimums: [CGFloat])) {
        self.weights = columns.weights; self.minimums = columns.minimums
    }

    /// Share by the longest cell in each column; never narrower than the longest unbreakable word
    /// (a time range like 03:00-12:20 stays on one line).
    static func columns(header: [String], rows: [[String]], size: CGFloat = 13) -> (weights: [CGFloat], minimums: [CGFloat]) {
        func units(_ character: Character) -> CGFloat { (character.unicodeScalars.first?.value ?? 0) > 0x2E80 ? 2 : 1 }
        func width(_ text: String) -> CGFloat { text.reduce(0) { $0 + units($1) } }
        func longestWord(_ text: String) -> CGFloat {
            var best: CGFloat = 0, run: CGFloat = 0
            for character in text {
                if character.isWhitespace || units(character) == 2 { best = max(best, run); run = 0; if units(character) == 2 { best = max(best, 2) } }
                else { run += 1 }
            }
            return max(best, run)
        }
        var weights: [CGFloat] = [], minimums: [CGFloat] = []
        for column in header.indices {
            let cells = ([header[column]] + rows.compactMap { column < $0.count ? $0[column] : nil }).map(ReflectionMarkdown.plain)
            weights.append(min(max(cells.map(width).max() ?? 1, 6), 48))
            minimums.append(min((cells.map(longestWord).max() ?? 1) * size * 0.62 + 24, 220))
        }
        let total = weights.reduce(0, +)
        return (weights.map { $0 / max(total, 1) }, minimums)
    }

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let floor = (0..<count).map { minimums.indices.contains($0) ? minimums[$0] : 40 }
        let weight = (0..<count).map { weights.indices.contains($0) ? weights[$0] : 1 / CGFloat(count) }
        var result = weight.map { total * $0 }
        // Lift columns below their minimum, then take that space from the others by weight.
        for _ in 0..<count {
            let short = result.indices.filter { result[$0] < floor[$0] - 0.5 }
            if short.isEmpty { break }
            let needed = short.reduce(0) { $0 + floor[$1] - result[$1] }
            for index in short { result[index] = floor[index] }
            let donors = result.indices.filter { !short.contains($0) && result[$0] > floor[$0] }
            let share = donors.reduce(0) { $0 + weight[$1] }
            guard share > 0 else { break }
            for index in donors { result[index] -= needed * weight[index] / share }
        }
        let sum = result.reduce(0, +)
        return sum > total && sum > 0 ? result.map { $0 * total / sum } : result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 640
        let columns = widths(total, count: subviews.count)
        let height = zip(subviews, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
            x += width
        }
    }
}
