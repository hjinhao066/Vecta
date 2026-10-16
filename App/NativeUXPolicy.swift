import Foundation

enum VectaUX {
    static func recordings(_ count:Int)->String {
        if VL.language == .english {return "\(count) "+(count==1 ? "recording":"recordings")}
        let n=abs(count),last=n%10,teen=n%100
        let noun=(11...14).contains(teen) ? VL.text("записей") : last==1 ? VL.text("запись") : (2...4).contains(last) ? VL.text("записи"):VL.text("записей")
        return "\(count) \(noun)"
    }
    static func taskValidation(_ title:String)->String? {
        title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? VL.text("Введите название задачи, чтобы сохранить её."):nil
    }
    static func templateValidation(title:String,prompt:String)->String? {
        if title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return VL.text("Введите название шаблона.")}
        if title.count>120 {return VL.text("Название: \(title.count) из 120 символов. Сократите название.")}
        if prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return VL.text("Добавьте инструкцию по структуре саммари.")}
        if prompt.count>6000 {return VL.text("Инструкция: \(prompt.count) из 6000 символов. Сократите текст.")}
        return nil
    }
    static func questionValidation(_ text:String)->String? {
        text.count>2000 ? VL.text("Вопрос: \(text.count) из 2000 символов. Сократите текст."):nil
    }
    static func utteranceLabel(start:Double,speaker:String?)->String {
        let time=start.isFinite ? max(0,Int(start)):0
        return String(format:VL.text("Реплика %d:%02d · %@"),time/60,time%60,speaker ?? VL.text("Неизвестный собеседник"))
    }
}

/// Summary-only versions share a conversation key; retranscription does not.
struct NativeTranscriptSelectionScope<RecordingID: Hashable>: Equatable {
    let recordingID: RecordingID
    let conversationKey: String
}

enum NativeUIStatePolicy {
    static func canSubmit<RecordingID: Hashable>(
        captured: NativeTranscriptSelectionScope<RecordingID>?,
        current: NativeTranscriptSelectionScope<RecordingID>?,
        selected: Set<Int>, available: Set<Int>
    ) -> Bool {
        captured != nil && captured == current && !selected.isEmpty && selected.isSubset(of: available)
    }

    /// Used on mount and on change; clearing first makes repeated delivery harmless.
    static func consumeExportRequest(_ requested: inout Bool) -> Bool {
        guard requested else { return false }
        requested = false
        return true
    }
}

enum NativeRecordingKeyboardPolicy {
    enum Action: Equatable { case toggle, previous, next }
    static func action(keyCode: UInt16, editing: Bool, modified: Bool, modal: Bool) -> Action? {
        guard !editing, !modified, !modal else { return nil }
        switch keyCode {
        case 49: return .toggle
        case 123, 126: return .previous
        case 124, 125: return .next
        default: return nil
        }
    }
    static func phraseIndex(starts: [Double], position: Double, focused: Int?, direction: Int) -> Int? {
        guard !starts.isEmpty, position.isFinite, starts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(starts, starts.dropFirst()).allSatisfy({ $0.0 <= $0.1 }) else { return nil }
        let current: Int?
        if let focused, starts.indices.contains(focused), abs(starts[focused] - position) < 0.1 { current = focused }
        else { current = starts.lastIndex { $0 <= position } }
        return min(starts.count - 1, max(0, (current ?? (direction > 0 ? -1 : 0)) + (direction > 0 ? 1 : -1)))
    }
}

/// Shared confirmation text keeps the destructive scope explicit.
enum NativeFactoryResetCopy {
    static let explanation = VL.text("Сброс удаляет все записи и настройки на устройстве PLAUD и отключает его от Vecta. Резервная копия не создаётся. Уже сохранённые на Mac аудио, расшифровки и саммари останутся.")
    static let confirmation = VL.text("Все записи на устройстве PLAUD будут удалены. Устройство будет отвязано.")
}

/// Recording IDs can be equal across libraries; bind work to owner objects too.
struct NativeLibraryOperationScope {
    let library: ObjectIdentifier
    let host: ObjectIdentifier
    let generation: UUID
    init(library: AnyObject, host: AnyObject, generation: UUID) {
        self.library = ObjectIdentifier(library); self.host = ObjectIdentifier(host); self.generation = generation
    }
    func isCurrent(library: AnyObject?, host: AnyObject?, generation: UUID, cancelled: Bool = false) -> Bool {
        !cancelled && self.generation == generation && library.map(ObjectIdentifier.init) == self.library && host.map(ObjectIdentifier.init) == self.host
    }
}

/// Keep a supported device's action visible while transport readiness changes.
struct NativeFastTransferAvailability {
    let supportedDevice: Bool
    let transferring: Bool
    let hasRecording: Bool
    let switching: Bool
    let transportReady: Bool
    var isVisible: Bool { supportedDevice && transferring && hasRecording && !switching }
    var isEnabled: Bool { isVisible && transportReady }
}
