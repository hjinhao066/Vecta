import Combine
import Foundation

/// "Start reflection" on the Daily Reflection page. Vecta pulls the recorder itself, then hands the rest to the
/// PLAUD pipeline on this Mac (launchd job local.plaud.daily-pipeline): it writes reflect-request.json and
/// kickstarts the job. The pipeline imports, transcribes and summarizes, and answers in reflect-status.json with
/// the same id. The job holds its own lock, so a press never runs a second copy beside the scheduled one, and it
/// keeps going after Vecta quits.
struct ReflectionRunFiles {
    let request: URL
    let status: URL
    let transcription: URL

    init(folder: URL) {
        request = folder.appendingPathComponent("reflect-request.json")
        status = folder.appendingPathComponent("reflect-status.json")
        transcription = folder.appendingPathComponent("transcription-status.json")
    }

    static var live: ReflectionRunFiles {
        #if VECTA_DEVELOPMENT
        // Screenshots and checks read a fixture folder; nothing is started.
        if let index = CommandLine.arguments.firstIndex(of: "--verify-reflection-run"), CommandLine.arguments.indices.contains(index + 1) {
            return ReflectionRunFiles(folder: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        #endif
        return ReflectionRunFiles(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PLAUD-Local/Manifests", isDirectory: true))
    }
}

/// What Vecta's own pull from the recorder is doing.
enum ReflectionPull: Equatable {
    case none
    case waitingForRecorder
    case copying(done: Int, total: Int)
    case failed(String)   // NativeMacModel failure code
    case finished
}

/// The pipeline's answer, read from reflect-status.json.
struct ReflectionAnswer: Equatable {
    let id: String
    let stage: String
    let reason: String?
    let sources: [String]
    let written: [String]
    let updatedAt: Date?

    static func read(_ url: URL) -> ReflectionAnswer? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, let stage = object["stage"] as? String else { return nil }
        return ReflectionAnswer(id: id, stage: stage, reason: object["reason"] as? String,
                                sources: object["sources"] as? [String] ?? [], written: object["written"] as? [String] ?? [],
                                updatedAt: (object["updated_at"] as? String).flatMap(ReflectionRunState.date))
    }

    var finished: Bool { stage == "done" || stage == "failed" }
}

/// transcription-status.json, written by the transcriber while it works on one file.
struct ReflectionTranscription: Equatable {
    let source: String?
    let completedSeconds: Double?
    let totalSeconds: Double?
    var state: String? = nil
    /// Where the transcriber runs when it is not this Mac ("windows"); written by the remote dispatcher.
    var machine: String? = nil
    var updatedAt: Date? = nil

    static func read(_ url: URL) -> ReflectionTranscription? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ReflectionTranscription(source: object["source"] as? String, completedSeconds: (object["completed_seconds"] as? NSNumber)?.doubleValue,
                                       totalSeconds: (object["total_seconds"] as? NSNumber)?.doubleValue,
                                       state: object["state"] as? String, machine: object["machine"] as? String,
                                       updatedAt: (object["updated_at"] as? String).flatMap(ReflectionRunState.date))
    }
}

struct ReflectionRunDisplay: Equatable {
    enum Tone: Equatable { case working, done, failed }
    let text: String
    let tone: Tone
    /// Progress of work nobody pressed a button for (the nightly job, another press): shown, but it does not lock the button.
    var ambient = false
    var busy: Bool { tone == .working && !ambient }
}

enum ReflectionRunState {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// Transcription older than this is a leftover, not progress.
    static let staleAfter: TimeInterval = 20 * 60

    /// "Transcribing 2/3 · 17% · about 2 h 10 min left · on the Windows PC", whoever started it. nil when nothing is running.
    static func ambient(_ transcription: ReflectionTranscription?, eta: TimeInterval?, now: Date = Date()) -> ReflectionRunDisplay? {
        guard let transcription, let state = transcription.state, ["decoding", "transcribing", "tagging"].contains(state),
              let updated = transcription.updatedAt, now.timeIntervalSince(updated) < staleAfter else { return nil }
        return ReflectionRunDisplay(text: progressLine(transcription, eta: eta, position: nil), tone: .working, ambient: true)
    }

    static func progressLine(_ transcription: ReflectionTranscription, eta: TimeInterval?, position: String?) -> String {
        var text: String
        switch transcription.state {
        case "decoding": text = VL.text("Preparing the audio")
        case "tagging": text = VL.text("Labelling the scenes")
        default:
            text = VL.text("Transcribing") + (position.map { " " + $0 } ?? "")
            if let done = transcription.completedSeconds, let length = transcription.totalSeconds, length > 0 {
                text += " · \(Int((min(done / length, 1) * 100).rounded()))%"
                if let eta, eta > 60 { text += " · " + VL.text("about") + " " + duration(eta) + " " + VL.text("left") }
            }
        }
        if transcription.machine == "windows" { text += " · " + VL.text("on the Windows PC") }
        return text
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Time left from the speed over the samples (time, seconds transcribed); nil until there is a trend worth quoting.
    static func eta(samples: [(Date, Double)], total: Double) -> TimeInterval? {
        guard let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) >= 120, last.1 > first.1, total > last.1 else { return nil }
        let speed = (last.1 - first.1) / last.0.timeIntervalSince(first.0)
        return (total - last.1) / speed
    }

    /// One short line next to the button. nil: nothing has been started.
    static func display(pull: ReflectionPull, requestID: String?, kickFailed: Bool, answer: ReflectionAnswer?,
                        transcription: ReflectionTranscription?, eta: TimeInterval? = nil, now: Date = Date()) -> ReflectionRunDisplay? {
        let live = ambient(transcription, eta: eta, now: now)
        switch pull {
        case .waitingForRecorder: return .init(text: VL.text("Ждём диктофон…"), tone: .working)
        case .copying(let done, let total):
            return .init(text: VL.text("Копируем с диктофона \(min(done + 1, total))/\(total)"), tone: .working)
        default: break
        }
        guard let requestID else { return live }
        if let live, answer == nil || answer?.finished == true || answer?.id != requestID { return live }
        if kickFailed { return .init(text: VL.text("Фоновая обработка на этом Mac не установлена"), tone: .failed) }
        guard let answer, answer.id == requestID else { return .init(text: VL.text("Ждём, пока закончится текущая обработка…"), tone: .working) }
        switch answer.stage {
        case "importing": return .init(text: VL.text("Забираем записи…"), tone: .working)
        case "waiting_audio": return .init(text: VL.text("Ждём, пока запись допишется…"), tone: .working)
        case "transcribing":
            let total = max(answer.sources.count, 1)
            let index = transcription?.source.flatMap { answer.sources.firstIndex(of: $0) }.map { $0 + 1 } ?? 1
            if let transcription, transcription.source == answer.sources[safe: index - 1],
               let done = transcription.completedSeconds, let length = transcription.totalSeconds, length > 0 {
                var shown = transcription
                if shown.state == nil { shown.state = "transcribing" }
                return .init(text: progressLine(shown, eta: eta, position: "\(index)/\(total)"), tone: .working)
            }
            return .init(text: VL.text("Расшифровываем \(index)/\(total)"), tone: .working)
        case "waiting_memory": return .init(text: VL.text("Мало свободной памяти — расшифровка начнётся сама"), tone: .working)
        case "reviewing": return .init(text: VL.text("Составляем итоги дня…"), tone: .working)
        case "done":
            if !answer.written.isEmpty {
                let time = answer.updatedAt.map { $0.formatted(.dateTime.hour().minute().locale(VL.locale)) } ?? ""
                return .init(text: VL.text("Готово · \(time)"), tone: .done)
            }
            if case .failed(let code) = pull { return .init(text: pullFailure(code), tone: .failed) }
            return .init(text: VL.text("Новых записей нет — итоги уже актуальны"), tone: .done)
        case "failed": return .init(text: pipelineFailure(answer.reason), tone: .failed)
        default: return .init(text: VL.text("Обрабатываем…"), tone: .working)
        }
    }

    static func pullFailure(_ code: String) -> String {
        switch code {
        case "recording": return VL.text("Диктофон ещё записывает — остановите запись и нажмите снова")
        case "timeout-scanning": return VL.text("Диктофон не найден рядом — включите его и нажмите снова")
        case "bluetooth-powered-off": return VL.text("Bluetooth выключен на Mac")
        case "bluetooth-permission-denied", "timeout-bluetooth": return VL.text("Vecta нет доступа к Bluetooth")
        case "timeout-list": return VL.text("Диктофон не отдал список записей — нажмите снова")
        default: return VL.text("Не удалось скопировать записи с диктофона")
        }
    }

    static func pipelineFailure(_ reason: String?) -> String {
        switch reason {
        case "quota": return VL.text("Лимит модели исчерпан — итоги составятся после сброса лимита")
        case "signed_out": return VL.text("Аккаунт для итогов вышел из системы")
        case "model_timeout": return VL.text("Модель не ответила вовремя — нажмите снова")
        case "transcribe": return VL.text("Расшифровка не удалась")
        case "drive": return VL.text("Итоги сохранены на Mac, но Google Drive пока их не принял")
        case "crash": return VL.text("Обработка неожиданно остановилась")
        default: return VL.text("Итоги дня не удалось составить")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The recorder side, implemented by NativeMacModel.
@MainActor protocol ReflectionPullSource: AnyObject {
    /// Starts (or joins) a pull. false: no recorder is set up, so there is nothing to pull.
    func startReflectionPull() -> Bool
    var reflectionPull: ReflectionPull { get }
}

@MainActor final class ReflectionRunController: ObservableObject {
    @Published private(set) var display: ReflectionRunDisplay?
    weak var source: ReflectionPullSource?
    private let files: ReflectionRunFiles
    private let kick: (@escaping (Bool) -> Void) -> Void
    private var pull = ReflectionPull.none
    private var pulling = false
    private var requestID: String?
    private var kickFailed = false
    private var timer: Timer?
    private var watcher: Timer?
    private var samples: [(Date, Double)] = []
    private var sampled: String?

    static let maxAge: TimeInterval = 12 * 3600   // the pipeline ignores older requests too

    init(files: ReflectionRunFiles = .live, kick: ((@escaping (Bool) -> Void) -> Void)? = nil) {
        self.files = files
        self.kick = kick ?? Self.kickstart
        // Coming back after a restart: keep showing the last press of the day.
        if let data = try? Data(contentsOf: files.request),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String, let at = (object["requested_at"] as? String).flatMap(ReflectionRunState.date),
           Date().timeIntervalSince(at) < Self.maxAge {
            requestID = id
        }
        update()
        if display?.busy == true { schedule() }
        // Transcription started by the nightly job or another press: keep the line current without a press.
        watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.update() } }
    }

    func start() {
        guard display?.busy != true else { return }
        kickFailed = false; requestID = nil; pull = .none
        if let source, source.startReflectionPull() {
            pulling = true; pull = .waitingForRecorder
        } else {
            submit()
        }
        update(); schedule()
    }

    /// Called every second while something is running.
    func tick() {
        if pulling, let source {
            pull = source.reflectionPull
            switch pull {
            case .finished, .failed, .none: pulling = false; submit()
            default: break
            }
        }
        update()
        if display?.busy != true { timer?.invalidate(); timer = nil }
    }

    private func submit() {
        let id = UUID().uuidString
        let object: [String: Any] = ["id": id, "requested_at": ISO8601DateFormatter().string(from: Date()), "source": "vecta"]
        do {
            try FileManager.default.createDirectory(at: files.request.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: files.request, options: .atomic)
        } catch { kickFailed = true; requestID = id; return }
        requestID = id
        kick { [weak self] ok in Task { @MainActor in
            guard let self, self.requestID == id else { return }
            if !ok { self.kickFailed = true }
            self.update()
        } }
    }

    private func update() {
        let transcription = ReflectionTranscription.read(files.transcription)
        var eta: TimeInterval?
        if let transcription, transcription.state == "transcribing", let done = transcription.completedSeconds, let total = transcription.totalSeconds {
            let key = (transcription.source ?? "") + "|" + String(Int(total))
            if key != sampled { sampled = key; samples = [] }
            if samples.last?.1 != done { samples.append((transcription.updatedAt ?? Date(), done)) }
            samples = samples.filter { ($0.0).timeIntervalSinceNow > -45 * 60 }
            eta = ReflectionRunState.eta(samples: samples, total: total)
        }
        let next = ReflectionRunState.display(pull: pull, requestID: requestID, kickFailed: kickFailed,
                                              answer: ReflectionAnswer.read(files.status), transcription: transcription, eta: eta)
        if next != display { display = next }
    }

    private func schedule() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    /// `launchctl kickstart` without -k: a running job is left alone and picks the request up when its round ends.
    nonisolated static func kickstart(_ done: @escaping (Bool) -> Void) {
        #if VECTA_DEVELOPMENT
        if CommandLine.arguments.contains("--verify-reflection-run") { done(true); return }
        #endif
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/local.plaud.daily-pipeline"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); done(process.terminationStatus == 0) } catch { done(false) }
        }
    }
}

#if VECTA_DEVELOPMENT
/// Screenshots only: the pull is read from pull.txt in the fixture folder ("waiting", "copying 1 3",
/// "failed recording", anything else = finished). No Bluetooth.
@MainActor final class ReflectionFixturePull: ReflectionPullSource {
    var files: ReflectionRunFiles?
    func startReflectionPull() -> Bool { files != nil }
    var reflectionPull: ReflectionPull {
        guard let url = files?.request.deletingLastPathComponent().appendingPathComponent("pull.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .finished }
        let parts = text.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        switch parts.first {
        case "waiting": return .waitingForRecorder
        case "copying" where parts.count == 3: return .copying(done: Int(parts[1]) ?? 0, total: Int(parts[2]) ?? 1)
        case "failed" where parts.count == 2: return .failed(parts[1])
        default: return .finished
        }
    }
}
#endif
