import Foundation

/// Synthetic checks for the Daily Reflection reader and the colour themes: no app launch, no user files.
@main enum DailyReflectionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            assertions += 1
            if !value { throw Failure(description: message) }
        }
        let month = """
        # 2026-10 每日反思

        ## 2026-10-24 周六

        <!-- one-thing:begin 2026-10-24 -->
        ### 要事复盘 · 原始
        - [ ] 1. 投出 3 份
        - [x] 2. 早睡
        <!-- one-thing:end 2026-10-24 -->

        <!-- plaud-recording:begin 2026-10-24 -->
        ### 录音整理 · 分析

        #### 一句话
        下午在家对着电脑口述。

        | 时间 | 事项 |
        |---|---|
        | 03:00-12:20 | 睡眠 |
        | 课间 | 聊天 \\| 投递 |

        原文：[2026-10-24_1350.md](../transcripts/2026-10-24_1350.md)
        <!-- plaud-recording:end 2026-10-24 -->

        ## 2026-10-25 周日

        ### 原始反思

        来源：`H:\\daily.md`

        **今日判断**
        - 注意力被盯盘占用。
          第二行接着写。
        """
        let days = DailyReflectionSource.split(month)
        try check(days.map(\.0) == ["2026-10-24", "2026-10-25"], "Each ## YYYY-MM-DD heading starts one day")
        try check(!days[0].1.contains("2026-10-25"), "A day ends at the next ## heading")
        try check(DailyReflectionSource.summary(days[0].1) == "下午在家对着电脑口述。", "The recording review's 一句话 is the summary")
        try check(DailyReflectionSource.summary(days[1].1) == "注意力被盯盘占用。", "Hermes 今日判断 is the summary, not the source line")

        let blocks = ReflectionMarkdown.parse(days[0].1)
        try check(!blocks.contains { if case .paragraph(let text) = $0 { return text.contains("<!--") } else { return false } }, "Source markers are not shown")
        try check(blocks.filter { $0 == .sourceBreak }.count == 1, "A divider separates the second source block")
        guard case .list(let tasks) = blocks.first(where: { if case .list = $0 { return true } else { return false } }) else { throw Failure(description: "Task list parsed") }
        try check(tasks.map(\.task) == [false, true] && tasks[0].text == "1. 投出 3 份", "Task boxes keep their state and text")
        guard case .table(let header, let rows) = blocks.first(where: { if case .table = $0 { return true } else { return false } }) else { throw Failure(description: "Table parsed") }
        try check(header == ["时间", "事项"] && rows.count == 2 && rows[1] == ["课间", "聊天 | 投递"], "Table cells split on unescaped pipes")
        let link = ReflectionMarkdown.inline("原文：[a.md](../transcripts/a.md)", base: URL(fileURLWithPath: "/tmp/review/daily", isDirectory: true))
        try check(link.runs.compactMap(\.link).first?.absoluteURL.path == "/tmp/review/transcripts/a.md", "Relative links resolve next to the monthly file")

        let hermes = ReflectionMarkdown.parse(days[1].1)
        guard case .list(let items) = hermes.last else { throw Failure(description: "Continuation list parsed") }
        try check(items.count == 1 && items[0].text == "注意力被盯盘占用。第二行接着写。", "Indented continuation lines join the item without a space between Chinese text")

        try check(ReflectionMarkdown.join(["Data", "Science"]) == "Data Science", "Latin soft breaks become spaces")
        let columns = ReflectionTableColumns.columns(header: header, rows: rows)
        try check(abs(columns.weights.reduce(0, +) - 1) < 0.001 && columns.minimums[0] > 13 * 0.62 * 11, "Columns share the width and keep time ranges on one line")

        for theme in VectaColorTheme.allCases {
            try check(theme.palette.count == VectaColorTheme.Role.allCases.count, "\(theme.rawValue) defines every colour role")
        }
        let classic = VectaColorTheme.classic.palette
        try check(classic[.canvas]! == (0xFAFAFA, 0x090A0B) && classic[.text]! == (0x171719, 0xF5F5F5) && classic[.accent]! == classic[.text]!, "Classic keeps the original black and white look")

        // Time allocation, task ids, ticks and the day transcript.
        let planned = """
        #### 待办
        - [ ] [12:51:30](vecta://reflection?day=2026-10-28&t=12:51:30) 整理 Mac 任务 <!-- rt-aa11bb22 -->
        - [ ] [13:16:02](vecta://reflection?day=2026-10-28&t=13:16:02) 算股市亏损 <!-- rt-cc33dd44 -->
        - [ ] 没有编号的一条

        #### 时间分配
        🟧🟧🟦

        - 🟧 **上班** 1 小时
        - 🟦 **上课** 0.5 小时

        覆盖 1.5 小时。
        <!-- plaud-hours {"hours": {"上课": 0.5, "上班": 1.0}, "colors": {"上班": "#F2A33A", "上课": "#4C8DF6"}, "notes": {"上班": "出餐"}, "covered": 1.5} -->

        #### 时间线
        - 12:00 在上班
        """
        let planBlocks = ReflectionMarkdown.parse(planned)
        var found: ReflectionHours?
        var planItems: [ReflectionListItem] = []
        for block in planBlocks {
            if case .hours(let value) = block { found = value }
            if case .list(let list) = block, planItems.isEmpty { planItems = list }
        }
        try check(planItems.count == 3 && planItems[0].id == "rt-aa11bb22" && planItems[1].id == "rt-cc33dd44" && planItems[2].id == nil, "Task ids come off the end of the line")
        try check(!planItems[0].text.contains("<!--") && planItems[0].text.contains("整理 Mac 任务"), "The id comment is not shown")
        try check(found?.entries.map(\.name) == ["上班", "上课"] && found?.entries[0].hex == "#F2A33A" && found?.entries[0].note == "出餐" && found?.covered == 1.5,
                  "Hours keep the review's category order, colours and notes")
        try check(planBlocks.contains { if case .paragraph(let text) = $0 { return text.contains("🟧") } else { return false } } == false
                  && planBlocks.contains { if case .list(let list) = $0 { return list.contains { $0.text.contains("1 小时") } } else { return false } } == false,
                  "The text version of the hours is replaced, not shown twice")
        try check(planBlocks.contains { if case .heading(_, let title) = $0 { return title == "时间线" } else { return false } }, "Sections after the hours block survive")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reflection-checks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let checks = ReflectionChecks(file: file)
        let three = [ReflectionListItem(level: 0, marker: nil, task: false, text: "a", id: "rt-1"),
                     ReflectionListItem(level: 0, marker: nil, task: false, text: "b", id: "rt-2"),
                     ReflectionListItem(level: 0, marker: nil, task: false, text: "c", id: "rt-3")]
        try check(checks.ordered(three).map(\.text) == ["a", "b", "c"], "Untouched tasks keep their written order")
        checks.set("rt-2", done: true, now: Date(timeIntervalSince1970: 100))
        try check(checks.ordered(three).map(\.text) == ["a", "c", "b"], "A ticked task drops to the bottom")
        checks.set("rt-1", done: true, now: Date(timeIntervalSince1970: 200))
        try check(checks.ordered(three).map(\.text) == ["c", "b", "a"], "Ticked tasks sit in the order they were ticked")
        checks.set("rt-2", done: false, now: Date(timeIntervalSince1970: 300))
        try check(checks.ordered(three).map(\.text) == ["b", "c", "a"], "Unticking returns the task to its written place")
        let reloaded = ReflectionChecks(file: file)
        try check(reloaded.isDone("rt-1", fallback: false) && !reloaded.isDone("rt-2", fallback: true) && reloaded.isDone("rt-9", fallback: true), "Ticks survive a restart; unknown ids use the file's own state")
        let mixed = [ReflectionListItem(level: 0, marker: nil, task: false, text: "x", id: "rt-1"), ReflectionListItem(level: 0, marker: nil, task: nil, text: "plain")]
        try check(reloaded.ordered(mixed).map(\.text) == ["x", "plain"], "A list that is not all tasks is left alone")

        let json = """
        {"day": "2026-10-28", "recordings": {"s1": {"audio": "/tmp/a.mp3", "start": "2026-10-28T12:51:00-07:00", "duration": 100.0}},
         "segments": [{"t": "12:51:30", "at": "x", "sha": "s1", "offset": 30.0, "end": 33.0, "speaker": "me", "text": "你好"},
                      {"t": "13:16:02", "at": "x", "sha": "s1", "offset": 60.0, "end": 63.0, "speaker": null, "text": "再见"}]}
        """
        let transcript = try JSONDecoder().decode(ReflectionTranscript.self, from: Data(json.utf8))
        try check(transcript.segment(at: "13:00:00")?.text == "再见" && transcript.segment(at: "12:51:30")?.text == "你好" && transcript.segment(at: "23:59:59")?.text == "再见",
                  "A link time finds the first sentence at or after it")
        print("PASS \(assertions) daily reflection and theme assertions")
    }
}
