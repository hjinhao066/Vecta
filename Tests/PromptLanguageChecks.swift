import Foundation

enum Worker {
    enum Failure: Error { case invalidInput, contextLimit, invalidOutput }
}

@main struct PromptLanguageChecks {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
    static func main() throws {
        require(tryLanguage(nil) == .russian, "historical absent language")
        require(tryLanguage("ru") == .russian, "explicit Russian")
        require(tryLanguage("en") == .english, "explicit English")
        let invalidLanguages: [Any] = ["de", "EN", "", " en", 42, true, NSNull()]
        for value in invalidLanguages {
            do {
                _ = try OutputLanguage.resolve(value)
                require(false, "invalid language accepted")
            } catch { require(true, "invalid language rejected") }
        }
        require(SummaryPrompt.instruction(for: .russian) == SummaryPrompt.instruction, "frozen Russian summary")
        require(SummaryPrompt.userPrefix(for: .russian) == SummaryPrompt.userPrefix, "Russian summary prefix")
        require(SummaryPrompt.userSuffix(for: .russian) == SummaryPrompt.userSuffix, "Russian summary suffix")
        require(LibraryPrompt.extraction(for: .russian) == LibraryPrompt.extraction, "Russian evidence extraction")
        require(LibraryPrompt.instruction(for: .russian) == LibraryPrompt.instruction, "Russian library answer")
        require(SemanticPrompt.instruction(for: .russian) == SemanticPrompt.instruction, "Russian semantic cards")
        require(SummaryPrompt.instruction(for: .english).contains("in English"), "English summary output policy")
        require(SummaryPrompt.userPrefix(for: .english).contains("TRANSCRIPT"), "English summary prefix")
        require(SummaryPrompt.userSuffix(for: .english).contains("END OF TRANSCRIPT"), "English summary suffix")
        require(LibraryPrompt.extraction(for: .english).contains("VERBATIM"), "evidence remains verbatim")
        require(LibraryPrompt.instruction(for: .english).contains("sourceIDs"), "English library evidence contract")
        require(LibraryPrompt.instruction(for: .english).contains("in English"), "English library answer output policy")
        require(LibraryPrompt.instruction(for: .english).contains("preserve evidence quotes verbatim"), "English answer preserves original-language evidence")
        require(SemanticPrompt.instruction(for: .english).contains("in English"), "English semantic output policy")
        require(SemanticPrompt.instruction(for: .english).contains("schemaVersion"), "English semantic schema")
        require(SummaryPrompt.temperature == 0 && SummaryPrompt.repetitionPenalty == 1, "evaluated decoding unchanged")
        let russianTasks=SummaryPrompt.plainTasks("## Поручения\n- Подготовить отчёт\n\nИтог\n- Не поручение",assistant:false)
        require(russianTasks.count == 1 && russianTasks[0]["description"] as? String == "Подготовить отчёт", "historical Russian explicit task section")
        for heading in ["Tasks", "Explicit tasks", "Accepted tasks", "Explicitly accepted tasks", "Assignments", "Explicit assignments", "Action items", "Accepted commitments"] {
            let text="## \(heading):\n- Prepare the report\n2. Send the draft\n\nConclusion\n- Not an assignment"
            let tasks=SummaryPrompt.plainTasks(text,assistant:false,language:.english)
            require(tasks.count == 2, "English explicit section recognized")
            require(tasks.first?["description"] as? String == "Prepare the report", "English task copied literally")
            require(tasks.first?["assignee"] is NSNull && tasks.first?["deadline"] is NSNull && (tasks.first?["sourceSegments"] as? [Int])?.isEmpty == true, "task metadata not invented")
            require(SummaryPrompt.plainTasks(text,assistant:true,language:.english).isEmpty, "assistant prose never imports tasks")
            require(SummaryPrompt.plainTasks(text,assistant:false).isEmpty, "historical Russian parser unchanged")
        }
        require(SummaryPrompt.plainTasks("Suggestions\n- Prepare a report",assistant:false,language:.english).isEmpty, "English suggestions are not accepted tasks")
        require(SummaryPrompt.plainTasks("Задачи\n- Подготовить отчёт",assistant:false,language:.english).isEmpty, "language snapshot scopes task parsing")
        for (text, language) in [("## Возражения клиента\n- Обсудить стоимость\n\n## Возможные шаги\n- Подготовить предложение", OutputLanguage.russian),
                                 ("## Client objections\n- Discuss pricing\n\n## Possible next steps\n- Prepare a proposal", OutputLanguage.english)] {
            require(SummaryPrompt.plainTasks(text, assistant: false, language: language).isEmpty, "custom analytical headings do not invent accepted tasks")
            require(SummaryPrompt.plainTasks(text, assistant: true, language: language).isEmpty, "custom assistant headings never import tasks")
        }
        print("PASS \(checks) model-free prompt-language checks; no model initialization, inference or user data")
    }
    static func tryLanguage(_ value: Any?) -> OutputLanguage? {
        try? OutputLanguage.resolve(value)
    }
}
