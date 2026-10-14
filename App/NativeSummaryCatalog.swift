import Foundation
import CryptoKit

/// A single presentation choice, adapted to the existing immutable request schema.
/// Templates have a neutral format envelope: no second structural prompt is mixed in.
struct NativeSummaryRecipe: Identifiable {
    let id: String
    let group: String
    let format: VectaSummaryInterpretation
    let template: AISummaryTemplate?
    var title: String { format.displayTitle }
    var detail: String { template?.prompt ?? format.detail }
}

enum NativeSummarySelection {
    static let defaultID = "format:detailed"
    static func recipes(formats: [VectaSummaryInterpretation], templates: [AISummaryTemplate]) -> [NativeSummaryRecipe] {
        let basic = ["detailed", "action_plan", "analytical", "nlp"]
        let formats = formats.map { NativeSummaryRecipe(id: "format:" + $0.id,
            group: basic.contains($0.id) ? VL.text("Основные") : VL.text("Мои"), format: $0, template: nil) }
        let builtinTemplates = Set(AISummaryTemplate.defaults.map(\.id))
        return formats + templates.filter { template in !builtinTemplates.contains(template.id) || AISummaryTemplate.defaults.first(where: { $0.id == template.id }) != template }.map { template in
            let hex = SHA256.hash(data: Data(("Vecta.summary-template:" + template.id).utf8)).map { String(format: "%02x", $0) }.joined()
            let chars = Array(hex.prefix(32))
            let uuid = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
            let envelope = VectaSummaryInterpretation(id: "custom_" + uuid, title: template.displayTitle,
                prompt: VL.text("Следуй структуре выбранного шаблона. Сохраняй проверяемые источники; не выдумывай факты, решения и договорённости."), revision: 1)
            return NativeSummaryRecipe(id: "template:" + template.id,
                group: VL.text("Мои"), format: envelope, template: template)
        }
    }
    /// New manual summaries expose only the primary formats; saved recipes remain intact.
    static func creationRecipes(in recipes: [NativeSummaryRecipe]) -> [NativeSummaryRecipe] {
        recipes.filter { $0.group == VL.text("Основные") }
    }
    static func selected(_ id: String?, legacyFormat: String?, in recipes: [NativeSummaryRecipe]) -> NativeSummaryRecipe? {
        if let id, let value = recipes.first(where: { $0.id == id }) { return value }
        if id == nil, let legacyFormat, let value = recipes.first(where: { $0.id == "format:" + legacyFormat }) { return value }
        return recipes.first(where: { $0.id == defaultID }) ?? recipes.first
    }
    static func transcriptSource(_ results: [AIProcessingResult]) -> UUID? {
        results.first { !($0.transcript ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && [.completed, .summaryFailed].contains($0.stage) }?.request.id
    }
}

/// The compact catalog is a presentation policy, never a destructive migration.
/// Old built-in IDs remain valid in saved requests, results and format storage.
enum NativeSummaryCatalog {
    static func visible(_ values: [VectaSummaryInterpretation]) -> [VectaSummaryInterpretation] {
        let builtins: [VectaSummaryInterpretation] = [.detailed, .actionPlan, .analytical, .nlp]
        let legacy: [VectaSummaryInterpretation] = [.legacyDetailed, .legacyActionPlan, .legacyAnalytical, .legacyNlp]
        let current = builtins.compactMap { builtin -> VectaSummaryInterpretation? in
            guard let saved = values.first(where: { $0.id == builtin.id }) else { return builtin }
            return legacy.contains(saved) ? builtin : saved
        }
        return current + values.filter { value in
            !value.isBuiltin || (!builtins.contains { $0.id == value.id } &&
                VectaSummaryInterpretation.allCases.first { $0.id == value.id } != value)
        }

    }
}


/// No secrets, raw server bodies or claims about the recorder's sleep state.
enum NativeConnectionMessage {
    static func failure(_ reason: String) -> String {
        switch reason {
        case "local-identity-save-failed": return VL.text("Не удалось сохранить ключи в Связке ключей macOS. Подключение остановлено до регистрации ключа на диктофоне; записи не изменены.")
        case "partner-network-timeout", "timeout-preparing": return VL.text("Сервис авторизации Plaud не ответил вовремя. Повторите синхронизацию.")
        case "partner-network-unavailable": return VL.text("Не удалось связаться с сервисом авторизации Plaud. Проверьте соединение с интернетом.")
        case "partner-http-401", "partner-http-403": return VL.text("Сервис Plaud отклонил авторизацию подключения. Данные и записи сохранены.")
        case "timeout-list": return VL.text("Plaud не передал полный список записей после повторных запросов. Записи на Mac сохранены. Повторите синхронизацию.")
        case "timeout-scanning": return VL.text("Выбранный Plaud не найден за время поиска. Можно повторить синхронизацию.")
        case "bluetooth-powered-off": return VL.text("Bluetooth выключен на Mac.")
        case "bluetooth-permission-denied": return VL.text("Разрешите Vecta доступ к Bluetooth в настройках macOS.")
        case "timeout-bluetooth": return VL.text("macOS не сообщила готовность Bluetooth. Проверьте разрешение Vecta на доступ к Bluetooth после разблокировки Mac.")
        default: return VL.text("Подключение остановлено: ") + reason
        }
    }
}
