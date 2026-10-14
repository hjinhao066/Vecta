import Foundation

/// A saved format is a value snapshot. Editing or deleting the catalog never
/// mutates the format attached to an earlier request or response.
struct VectaSummaryInterpretation: Codable, Equatable, Identifiable, CaseIterable {
    let id: String
    let title: String
    let prompt: String
    let revision: Int

    var rawValue: String { id }
    var isBuiltin: Bool { Self.allCases.contains { $0.id == id } }
    var isValid: Bool {
        let knownID = Self.allCases.contains { $0.id == id }
        let customID = id.hasPrefix("custom_") && UUID(uuidString: String(id.dropFirst(7)))?.uuidString.lowercased() == String(id.dropFirst(7))
        return (knownID || customID) && (1...1_000_000).contains(revision)
            && !title.isEmpty && title.count <= 120 && title.utf8.count <= 512
            && title == title.trimmingCharacters(in: .whitespacesAndNewlines)
            && !title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !prompt.isEmpty && prompt.count <= 12_000 && prompt.utf8.count <= 48_000
            && prompt == prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            && !prompt.unicodeScalars.contains { $0.value < 32 && $0.value != 9 && $0.value != 10 }
    }

    var detail: String {
        if let original = Self.allCases.first(where: { $0.id == id }), original == self {
            switch id {
            case "brief": return VL.text("Чтобы за минуту понять, о чём говорили")
            case "standard": return VL.text("Для встреч, интервью и рабочих обсуждений")
            case "analytical": return VL.text("Для глубокого анализа решений, рисков и договорённостей")
            case "action_plan": return VL.text("Задачи, решения и следующие шаги.")
            case "detailed": return VL.text("Темы, объяснения, аргументы и важные детали записи")
            case "insights": return VL.text("Наблюдения, полезные связи, возможности и риски.")
            case "nlp": return VL.text("Языковые паттерны, рамки общения и обоснованные гипотезы.")
            default: break
            }
        }
        return String(prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(180))
    }

    init(id: String, title: String, prompt: String, revision: Int) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.revision = revision
    }

    /// V1 has no snapshot and can identify only the original built-in formats.
    init?(rawValue: String) {
        guard let original = Self.allCases.first(where: { $0.id == rawValue }) else { return nil }
        self = original
    }

    static func decodeSnapshot(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any], Set(object.keys) == Set(["id", "title", "prompt", "revision"]),
              let revision = object["revision"] as? NSNumber,
              ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: revision.objCType)),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data), snapshot.isValid else { return nil }
        return snapshot
    }

    private var shippedDefinition:Bool {
        (Self.allCases+[Self.legacyAnalytical,Self.legacyActionPlan,Self.legacyDetailed,Self.legacyNlp,Self(id:"brief",title:"Краткое",prompt:Self.legacyBriefPrompt,revision:1)]).contains(self)
    }
    var displayTitle:String {shippedDefinition ? VL.string(title):title}
    func localizedPrompt(in language:VectaLanguage)->String {shippedDefinition ? VL.string(prompt,in:language):prompt}

    static let legacyAnalytical = VectaSummaryInterpretation(id:"analytical",title:"Аналитическое",prompt:"Глубокий анализ: краткий вывод, темы, позиции участников, проблемы, причины и аргументы, решения, задачи и ответственные, риски, противоречия, нерешённые вопросы и возможные следующие шаги. Явно разделяй факты разговора, выводы модели и предположения. Не представляй предположения как факты; не выдумывай имена, цифры, сроки или обязательства.",revision:1)
    static let legacyActionPlan = VectaSummaryInterpretation(id: "action_plan", title: "План действий", prompt: "Выбранный формат саммари: план действий. Отдельно выпиши принятые решения и предложения. Для каждой задачи укажи действие, ответственного только если он назван явно, буквально прозвучавший срок, препятствия и открытые вопросы. Не придумывай исполнителей и даты; неизвестные поля помечай явно.", revision: 1)
    static let legacyDetailed = VectaSummaryInterpretation(id: "detailed", title: "Подробное", prompt: "Выбранный формат саммари: подробный тематический конспект. Для каждой темы сохрани тезисы, аргументы, примеры, разногласия, риски и итог. Сохрани значимые числа и даты точно. Отдели выводы участников от своих предположений.", revision: 1)
    static let legacyNlp = VectaSummaryInterpretation(id: "nlp", title: "Разбор общения", prompt: "Выбранный формат саммари: нейролингвистический разбор общения. Рассмотри метамодель: обобщения, опущения, причинно-следственные формулировки; рамки обсуждения, раппорт/сотрудничество и приёмы убеждения. Подкрепи наблюдения короткими точными цитатами, указанием собеседника и контекста. Приведи альтернативные объяснения и варианты более ясных уточняющих вопросов. Не ставь диагнозы, не определяй личность, не приписывай скрытые намерения или достоверные психологические состояния. Возможные интерпретации помечай как гипотезы.", revision: 1)
    static var allCases: [Self] { [brief, standard, detailed, analytical, actionPlan, insights, nlp] }
    static let legacyBriefPrompt = "Выбранный формат саммари: краткое резюме до 150 слов, пять главных выводов и основное принятое решение. Если решения нет, укажи это; не дополняй запись вымышленными выводами ради количества."
    static let brief = VectaSummaryInterpretation(id: "brief", title: "Краткое", prompt: "Краткое саммари до 150 слов: основная тема, ключевые мысли, главный результат. Чтобы за минуту понять, о чём говорили. Не пересказывай реплики дословно, не добавляй искусственные решения, задачи и пустые разделы. Число выводов определяется содержанием разговора.", revision: 2)
    static let standard = VectaSummaryInterpretation(id:"standard",title:"Стандартное",prompt:"Общая информация, обсуждённые темы, основные выводы, принятые решения, задачи и договорённости, открытые вопросы. Не создавай пустых разделов или вымышленных решений.",revision:1)
    static let analytical = VectaSummaryInterpretation(id: "analytical", title: "Аналитический разбор", prompt: "Аналитический разбор: главный вывод, причинно-следственные связи, аргументы и позиции участников, противоречия, допущения, альтернативы, риски и открытые вопросы. Структура должна объяснять, почему обсуждение привело к результату, а не повторять конспект. Отделяй факты записи, выводы модели и гипотезы. Не выдумывай цифры, имена, сроки, решения и обязательства.", revision: 2)
    static let actionPlan = VectaSummaryInterpretation(id: "action_plan", title: "Решения и задачи", prompt: "Решения и задачи: отдельно принятые решения, конкретные действия и предложения, которые ещё не согласованы. Для задачи указывай исполнителя и срок только если они прямо названы; иначе явно отмечай, что они не указаны. Покажи зависимости, препятствия и вопросы, требующие решения. Не превращай предложение или обсуждение в договорённость и не создавай пустые разделы.", revision: 2)
    static let detailed = VectaSummaryInterpretation(id: "detailed", title: "Конспект", prompt: "Тематический конспект: понятно и полно раскрой содержание записи по темам. Сохрани ключевые мысли, объяснения, аргументы, важные детали, примеры, числа, даты, разногласия и итог каждой темы. Объём определяется содержанием, без искусственного ограничения числа слов и тезисов. Не добавляй вымышленных решений и задач. Отделяй сказанное участниками от предположений.", revision: 2)
    static let insights = VectaSummaryInterpretation(id: "insights", title: "Идеи и выводы", prompt: "Выбранный формат саммари: инсайты. Дай значимые наблюдения, повторяющиеся темы, потребности и возможности; каждое наблюдение подкрепи точной короткой цитатой с обозначением собеседника. Возможные объяснения и гипотезы помечай отдельно; не обобщай за пределы имеющейся записи.", revision: 1)
    static let nlp = VectaSummaryInterpretation(id: "nlp", title: "Психологический разбор", prompt: "Психологический разбор коммуникации: исследуй формулировки, обобщения, опущения, причинно-следственные связки, рамки обсуждения, сотрудничество и приёмы убеждения. Покажи наблюдаемые эмоциональные акценты и языковые паттерны с точными короткими цитатами и контекстом. Возможные объяснения помечай как гипотезы, приводи альтернативы и уточняющие вопросы. Не ставь диагнозы, не определяй личность и не приписывай скрытые намерения или достоверные психологические состояния.", revision: 2)
}

struct VectaSavedAnalysisRequestIdentity: Equatable {
    let filename: String
    let sourceSHA256: String
    let requestID: String
    let interpretation: VectaSummaryInterpretation
}

struct VectaSavedAnalysisRequest: Equatable {
    let identity: VectaSavedAnalysisRequestIdentity
    let requestedAt: Date
}

struct VectaSavedAnalysisSnapshot {
    let requests: [VectaSavedAnalysisRequest]
    let results: [VectaSavedAnalysisResult]
    let submissions: [VectaSavedAnalysisSubmission]
}

/// Current output belongs to the immutable request, even when an older request
/// for the same format completes later. History selection is handled separately.
enum VectaSavedAnalysisAssociation {
    static func currentRequest(for interpretation: VectaSummaryInterpretation, in requests: [VectaSavedAnalysisRequest]) -> VectaSavedAnalysisRequest? {
        requests.filter { $0.identity.interpretation == interpretation }.max {
            $0.requestedAt == $1.requestedAt
                ? $0.identity.requestID < $1.identity.requestID : $0.requestedAt < $1.requestedAt
        }
    }

    static func result(for request: VectaSavedAnalysisRequest?, in results: [VectaSavedAnalysisResult]) -> VectaSavedAnalysisResult? {
        guard let request else { return nil }
        return results.filter { $0.requestIdentity == request.identity }.max { $0.completedAt < $1.completedAt }
    }

    static func submission(for request: VectaSavedAnalysisRequest?, in submissions: [VectaSavedAnalysisSubmission]) -> VectaSavedAnalysisSubmission? {
        guard let request else { return nil }
        return submissions.filter { $0.requestIdentity == request.identity }.max { $0.updatedAt < $1.updatedAt }
    }
}

struct VectaSavedAnalysisResult: Identifiable, Equatable {
    let id: String
    let interpretation: VectaSummaryInterpretation
    let body: String
    let completedAt: Date
    let conversationURL: URL
    let requestIdentity: VectaSavedAnalysisRequestIdentity?

    init(id: String, interpretation: VectaSummaryInterpretation, body: String, completedAt: Date,
         conversationURL: URL, requestIdentity: VectaSavedAnalysisRequestIdentity? = nil) {
        self.id = id
        self.interpretation = interpretation
        self.body = body
        self.completedAt = completedAt
        self.conversationURL = conversationURL
        self.requestIdentity = requestIdentity
    }

    var title: String { interpretation.title }
}

enum VectaSavedAnalysisSubmissionPhase: String, Codable {
    case pending, claimed, failed, completed
    case awaitingResult = "awaiting_result"
    case needsReview = "needs_review"

    var isActive: Bool { self == .pending || self == .claimed || self == .awaitingResult }
}

struct VectaSavedAnalysisSubmission: Equatable {
    let id: String
    let interpretation: VectaSummaryInterpretation
    let phase: VectaSavedAnalysisSubmissionPhase
    let updatedAt: Date
    let error: String?
    let conversationURL: URL?
    let requestIdentity: VectaSavedAnalysisRequestIdentity

    // Imported historical state only; never starts a network operation.
    var message: String { VL.text("Состояние ранее сохранённого результата: ") + phase.rawValue }
}
