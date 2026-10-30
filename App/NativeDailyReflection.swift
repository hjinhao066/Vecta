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
            // "none" shows the state where no review folder exists on this Mac.
            return CommandLine.arguments[index + 1] == "none" ? nil : URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
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
    /// Stable id from a trailing `<!-- rt-xxxxxxxx -->`: the tick state is kept per id, never in the file.
    var id: String? = nil
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
    /// The day's time allocation, from a `<!-- plaud-hours {...} -->` line; replaces the plain-text version above it.
    case hours(ReflectionHours)
}

/// A small block parser for the review files: headings, paragraphs, nested and task lists,
/// tables, code, quotes and rules. Inline styling and links go through Foundation's Markdown.
enum ReflectionMarkdown {
    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])\s+(.*)$"#)
    private static let taskBox = try! NSRegularExpression(pattern: #"^\[([ xX])\]\s+(.*)$"#)
    private static let taskID = try! NSRegularExpression(pattern: #"\s*<!--\s*(rt-[0-9a-f]{4,})\s*-->\s*$"#)
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
            if line.hasPrefix("<!-- plaud-hours "), let hours = ReflectionHours(comment: line) {
                flush()
                // The text version (colour squares and one line per category) sits between the heading and this marker.
                while let last = blocks.last {
                    if case .heading = last { break }
                    if last == .sourceBreak { break }
                    blocks.removeLast()
                }
                blocks.append(.hours(hours))
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
                var itemID: String?
                if let tag = taskID.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                   let whole = Range(tag.range, in: body), let name = Range(tag.range(at: 1), in: body) {
                    itemID = String(body[name]); body.removeSubrange(whole)
                }
                items.append(ReflectionListItem(level: min(indent / 2, 6), marker: marker.first?.isNumber == true ? marker : nil, task: task, text: body, id: itemID))
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
        // No width offered (ideal size): the narrowest width that keeps every word whole.
        let total = proposal.width ?? minimums.reduce(0, +)
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


// MARK: - Time allocation, ticks and the day transcript

/// One day's time allocation: category, hours, colour and a one-line note, in the order the review lists them.
struct ReflectionHours: Equatable {
    struct Entry: Equatable, Identifiable {
        let name: String
        let hours: Double
        let hex: String
        let note: String
        var id: String { name }
    }
    let entries: [Entry]
    let covered: Double?

    static let order = ["上班", "上课", "AI项目", "求职", "通勤", "吃饭", "看剧刷手机", "安静", "其他"]
    static let fallbackHex = "#8E97A8"

    var total: Double { entries.reduce(0) { $0 + $1.hours } }

    init(entries: [Entry], covered: Double?) { self.entries = entries; self.covered = covered }

    /// `<!-- plaud-hours {"hours": {...}, "colors": {...}, "notes": {...}, "covered": 10.3} -->`
    init?(comment: String) {
        guard let open = comment.firstIndex(of: "{"), let close = comment.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(comment[open...close].utf8)) as? [String: Any],
              let hours = object["hours"] as? [String: Any] else { return nil }
        let colors = object["colors"] as? [String: String] ?? [:], notes = object["notes"] as? [String: String] ?? [:]
        let names = hours.keys.sorted {
            let a = Self.order.firstIndex(of: $0) ?? Self.order.count, b = Self.order.firstIndex(of: $1) ?? Self.order.count
            return a == b ? $0 < $1 : a < b
        }
        let entries = names.compactMap { name -> Entry? in
            guard let value = (hours[name] as? NSNumber)?.doubleValue, value > 0 else { return nil }
            return Entry(name: name, hours: value, hex: colors[name] ?? Self.fallbackHex, note: notes[name] ?? "")
        }
        guard !entries.isEmpty else { return nil }
        self.init(entries: entries, covered: (object["covered"] as? NSNumber)?.doubleValue)
    }
}

/// The ticks on review todos. They live beside the pipeline's own files and never touch the Drive copy, so
/// a tick made here survives the review being rewritten, and the pipeline can read it back.
@MainActor final class ReflectionChecks: ObservableObject {
    static let shared = ReflectionChecks()
    struct Mark: Equatable { let done: Bool; let at: Date }

    @Published private(set) var marks: [String: Mark] = [:]
    private let file: URL

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PLAUD-Local/Manifests/reflection-checks.json")) {
        self.file = file
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        let stamp = ISO8601DateFormatter()
        var loaded: [String: Mark] = [:]
        for (id, value) in object {
            loaded[id] = Mark(done: value["done"] as? Bool ?? false, at: (value["at"] as? String).flatMap(stamp.date) ?? .distantPast)
        }
        if loaded != marks { marks = loaded }
    }

    func isDone(_ id: String, fallback: Bool) -> Bool { marks[id]?.done ?? fallback }

    func set(_ id: String, done: Bool, now: Date = Date()) {
        marks[id] = Mark(done: done, at: now)
        let stamp = ISO8601DateFormatter()
        let object = marks.mapValues { ["done": $0.done, "at": stamp.string(from: $0.at)] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Open items first in their written order, then the ticked ones, earliest tick first: a ticked item drops to the
    /// bottom and an unticked one returns to where it was written.
    func ordered(_ items: [ReflectionListItem]) -> [ReflectionListItem] {
        guard items.allSatisfy({ $0.id != nil && $0.task != nil }) else { return items }
        let state = items.map { isDone($0.id ?? "", fallback: $0.task ?? false) }
        let open = items.indices.filter { !state[$0] }
        let done = items.indices.filter { state[$0] }.sorted {
            let a = marks[items[$0].id ?? ""]?.at ?? .distantPast, b = marks[items[$1].id ?? ""]?.at ?? .distantPast
            return a == b ? $0 < $1 : a < b
        }
        return (open + done).map { items[$0] }
    }
}

/// A whole day as one transcript: every sentence with its clock time and where its audio is.
struct ReflectionTranscript: Decodable, Equatable {
    struct Recording: Decodable, Equatable { let audio: String?; let start: String; let duration: Double }
    struct Segment: Decodable, Equatable, Identifiable {
        let t: String
        let sha: String
        let offset: Double
        let end: Double
        let speaker: String?
        let text: String
        var id: String { t + sha + String(offset) }
    }
    let day: String
    let recordings: [String: Recording]
    let segments: [Segment]

    /// The sentence a `HH:MM:SS` link points at: the first one at or after it, else the last one before it.
    func segment(at time: String) -> Segment? {
        segments.first { $0.t >= time } ?? segments.last
    }

    static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("PLAUD-Local/Reflection", isDirectory: true)
    }

    static func load(day: String, folder: URL = folder()) -> ReflectionTranscript? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(day).逐字稿.json")) else { return nil }
        return try? JSONDecoder().decode(ReflectionTranscript.self, from: data)
    }
}
