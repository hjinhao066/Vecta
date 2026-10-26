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
        print("PASS \(assertions) daily reflection and theme assertions")
    }
}
