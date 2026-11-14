import AppKit
import SwiftUI

/// Ask Claude about the daily reviews. Each question runs the user's own Claude Code CLI (`claude -p`)
/// with read-only file tools pointed at the review folder and the day transcripts; follow-up questions
/// resume the same CLI session so the conversation keeps its context. Nothing here writes files.
enum ReflectionChatModel: String, CaseIterable, Identifiable {
    case haiku = "claude-haiku-5-5", sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5"
    var id: String { rawValue }
    var title: String {
        switch self { case .haiku: return "Haiku 5.5"; case .sonnet: return "Sonnet 5.5"; case .opus: return "Opus 5.5" }
    }
}

struct ReflectionChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var failed = false
}

@MainActor final class ReflectionChatController: ObservableObject {
    static let shared = ReflectionChatController()
    static let modelKey = "Vecta.reflectionChat.model"

    @Published private(set) var messages: [ReflectionChatMessage] = []
    @Published private(set) var busy = false
    /// What the CLI is doing right now ("Searching transcripts…"), shown under the last question.
    @Published private(set) var activity: String?
    private var sessionID: String?
    private var seat: String?
    private var process: Process?

    var model: ReflectionChatModel {
        ReflectionChatModel(rawValue: VL.preferences.string(forKey: Self.modelKey) ?? "") ?? .sonnet
    }

    func reset() {
        stop()
        messages = []; sessionID = nil; activity = nil
    }

    func stop() {
        process?.terminate(); process = nil
        if busy { finish(error: nil) }
    }

    func ask(_ raw: String, reviewFolder: URL?) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        guard let claude = Self.claudeExecutable() else {
            messages.append(.init(role: .user, text: question))
            messages.append(.init(role: .assistant, text: VL.text("Claude Code CLI not found. Install it, sign in once with `claude`, then ask again."), failed: true))
            return
        }
        messages.append(.init(role: .user, text: question))
        messages.append(.init(role: .assistant, text: ""))
        busy = true; activity = VL.text("Thinking…")
        let resume = sessionID, model = model.rawValue
        let seats = seat.map { [$0] } ?? Self.seats()
        let system = Self.systemPrompt(reviewFolder: reviewFolder)
        let directories = [reviewFolder, ReflectionTranscript.folder()].compactMap { $0 }
        run(claude: claude, question: question, model: model, resume: resume, system: system, directories: directories, seats: seats)
    }

    // MARK: - CLI

    private func run(claude: URL, question: String, model: String, resume: String?, system: String, directories: [URL], seats: [String?]) {
        guard let current = seats.first else { finish(error: VL.text("No signed-in Claude account answered.")); return }
        let process = Process()
        process.executableURL = claude
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--model", model, "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob",
                         "--setting-sources", "", "--strict-mcp-config", "--append-system-prompt", system]
        for directory in directories { arguments += ["--add-dir", directory.path] }
        if let resume { arguments += ["--resume", resume] }
        process.arguments = arguments
        let home = FileManager.default.homeDirectoryForCurrentUser
        var environment = ["HOME": home.path, "USER": NSUserName(), "LANG": "en_US.UTF-8",
                           "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        if let current { environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(current).path }
        process.environment = environment
        process.currentDirectoryURL = ReflectionTranscript.folder()
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice

        let reader = ReflectionChatLineReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // End of output: every event line is already queued on the main queue ahead of this.
                handle.readabilityHandler = nil
                DispatchQueue.main.async { [weak self] in self?.ended(process, seats: seats, retry: { [weak self] in
                    self?.run(claude: claude, question: question, model: model, resume: nil, system: system, directories: directories, seats: Array(seats.dropFirst()))
                }) }
                return
            }
            for event in reader.events(appending: chunk) {
                DispatchQueue.main.async { [weak self] in self?.handle(event, seat: current) }
            }
        }
        do {
            self.process = process
            try process.run()
            input.fileHandleForWriting.write(Data(question.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            self.process = nil
            finish(error: VL.text("Could not start Claude Code: ") + error.localizedDescription)
        }
    }

    /// Set when an account says it is signed out or out of quota, so the next one is tried.
    private var retrySeat = false

    private func ended(_ finished: Process, seats: [String?], retry: @escaping () -> Void) {
        guard process === finished else { return }
        process = nil
        if retrySeat {
            retrySeat = false
            if seats.count > 1 { retry(); return }
            finish(error: VL.text("No signed-in Claude account answered. Run `claude` in Terminal and sign in."))
            return
        }
        if busy { finish(error: VL.text("Claude stopped without an answer.")) }
    }

    private func handle(_ event: [String: Any], seat current: String?) {
        guard busy, var last = messages.last, last.role == .assistant else { return }
        switch event["type"] as? String {
        case "system":
            if let id = event["session_id"] as? String { sessionID = id }
        case "stream_event":
            guard let inner = event["event"] as? [String: Any] else { return }
            switch inner["type"] as? String {
            case "message_start":
                // Each model turn streams afresh; only the final turn's text is the answer.
                last.text = ""; messages[messages.count - 1] = last
            case "content_block_delta":
                if let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    last.text += text; messages[messages.count - 1] = last
                    activity = nil
                }
            default: break
            }
        case "assistant":
            let content = ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content where block["type"] as? String == "tool_use" {
                activity = Self.describe(tool: block["name"] as? String, input: block["input"] as? [String: Any])
            }
        case "result":
            let text = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if event["is_error"] as? Bool == true {
                let lower = text.lowercased()
                if lower.contains("not logged in") || lower.contains("limit") || lower.contains("credit") || lower.contains("/login") {
                    retrySeat = true; sessionID = nil; return
                }
                finish(error: text.isEmpty ? VL.text("Claude returned an error.") : text)
                return
            }
            seat = current
            if let id = event["session_id"] as? String { sessionID = id }
            if !text.isEmpty { last.text = text; messages[messages.count - 1] = last }
            finish(error: nil)
        default: break
        }
    }

    private func finish(error: String?) {
        busy = false; activity = nil
        guard var last = messages.last, last.role == .assistant else { return }
        if let error { last.text = last.text.isEmpty ? error : last.text + "\n\n" + error; last.failed = true }
        else if last.text.isEmpty { last.text = VL.text("Stopped.") ; last.failed = true }
        messages[messages.count - 1] = last
    }

    private static func describe(tool: String?, input: [String: Any]?) -> String {
        let path = (input?["path"] as? String) ?? (input?["file_path"] as? String) ?? (input?["glob"] as? String) ?? ""
        let what = path.contains("逐字稿") ? VL.text("transcripts") : VL.text("reviews")
        switch tool {
        case "Grep":
            let pattern = (input?["pattern"] as? String).map { " “\($0.prefix(40))”" } ?? ""
            return VL.text("Searching ") + what + pattern
        case "Read": return VL.text("Reading ") + what
        default: return VL.text("Looking through ") + what
        }
    }

    // MARK: - Setup

    static func claudeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home.appendingPathComponent(".local/bin/claude").path, home.appendingPathComponent(".claude/local/claude").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Claude accounts signed in on this Mac: extra config folders (`~/.claude-*` with a login) first, then the default.
    static func seats() -> [String?] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".claude-") && FileManager.default.fileExists(atPath: home.appendingPathComponent($0).appendingPathComponent(".claude.json").path) }
            .sorted()
        return names.map { Optional($0) } + [nil]
    }

    static func systemPrompt(reviewFolder: URL?, today: Date = Date()) -> String {
        let transcripts = ReflectionTranscript.folder().path
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd EEEE"
        return """
        你在 Vecta 的 Daily Reflection 页面里，回答用户关于自己过去每一天的问题。今天是 \(day.string(from: today))。
        数据都在本机，只读，用 Grep/Glob/Read 自己查，不要凭空回答：
        1. 每日复盘：\(reviewFolder?.path ?? "（这台 Mac 上没找到）")/YYYY-MM.md，每天一节，以 `## YYYY-MM-DD` 开头。
        2. 周复盘、月复盘：\(transcripts)/week-YYYY-Www.md、month-YYYY-MM.md。
        3. 每天的完整逐字稿：\(transcripts)/YYYY-MM-DD.逐字稿.md，每行 `[HH:MM:SS] [我|他人|?] 文本`。单个文件几十万字，不要整份读：先 Grep 关键词（中英文、同音字、常见误写都试，人名常被写错，比如 Luca 可能是 Luka/卢卡），再用 Read 带 offset/limit 看命中前后几十行。
        回答用中文，术语和英文原话保留英文；先给结论，再给依据。引用逐字稿时附可点击的链接，格式 [11-11 13:38](vecta://reflection?day=2026-11-11&t=13:38:37)，t 用逐字稿里那一行的时间。
        逐字稿是机器转写，会漏句和错字；查不到或不确定就直说，并说明查了哪些词、哪几天。
        """
    }
}

/// Splits the CLI's stream-json output into one decoded event per line.
final class ReflectionChatLineReader: @unchecked Sendable {
    private var buffer = Data()
    func events(appending chunk: Data) -> [[String: Any]] {
        buffer.append(chunk)
        var result: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { result.append(event) }
        }
        return result
    }
}

// MARK: - View

struct ReflectionChatPane: View {
    @ObservedObject var chat: ReflectionChatController
    let reviewFolder: URL?
    let compact: Bool
    let jump: (String, String) -> Void
    @AppStorage(ReflectionChatController.modelKey, store: VL.preferences) private var modelID = ReflectionChatModel.sonnet.rawValue
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var selectedModel: ReflectionChatModel { ReflectionChatModel(rawValue: modelID) ?? .sonnet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(VL.text("Ask AI")).font(.system(size: compact ? 19 : 22, weight: .semibold)).foregroundColor(Ink.text)
                Spacer(minLength: 0)
                Menu {
                    Picker("", selection: $modelID) {
                        ForEach(ReflectionChatModel.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedModel.title).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.foregroundColor(Ink.secondary).padding(.horizontal, 10).frame(height: 30).background(Ink.elevated).cornerRadius(7)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(VL.text("Model")).accessibilityLabel(VL.text("Model"))
                Button { chat.reset(); focused = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).foregroundColor(Ink.secondary).background(Ink.elevated).cornerRadius(7)
                    .disabled(chat.messages.isEmpty).opacity(chat.messages.isEmpty ? 0.45 : 1)
                    .help(VL.text("New chat")).accessibilityLabel(VL.text("New chat"))
            }.padding(.horizontal, compact ? 20 : 36).padding(.top, 22).padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if chat.messages.isEmpty { suggestions }
                        ForEach(chat.messages) { message in bubble(message).id(message.id) }
                        if let activity = chat.activity {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(activity).font(.system(size: 12)).foregroundColor(Ink.secondary).lineLimit(1)
                            }.id("activity")
                        }
                    }.frame(maxWidth: 820, alignment: .leading).padding(.horizontal, compact ? 20 : 36).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) { _ in
                    if let last = chat.messages.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }

            composer.padding(.horizontal, compact ? 16 : 32).padding(.bottom, 18).padding(.top, 6)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = NativeDailyReflectionScreen.reflectionLink(url) else { return NSWorkspace.shared.open(url.absoluteURL) ? .handled : .systemAction }
            jump(link.day, link.time)
            return .handled
        })
        .onAppear { focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([VL.text("What did I get done this week?"), VL.text("Who invited me to a movie night, and which movie?"), VL.text("Which to-dos have I been putting off longest?")], id: \.self) { text in
                Button { send(text) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundColor(Ink.muted)
                        Text(text).font(.system(size: 13)).foregroundColor(Ink.secondary)
                    }.padding(.vertical, 7).padding(.horizontal, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).background(Ink.surface).cornerRadius(7)
            }
        }.padding(.top, 4)
    }

    @ViewBuilder private func bubble(_ message: ReflectionChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack { Spacer(minLength: 60)
                Text(message.text).font(.system(size: 13.5)).foregroundColor(Ink.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Ink.selection).cornerRadius(10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .assistant:
            if message.failed {
                Text(message.text).font(.system(size: 13)).foregroundColor(Ink.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if !message.text.isEmpty {
                ReflectionMarkdownView(blocks: ReflectionMarkdown.parse(message.text), base: reviewFolder, jump: jump)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(VL.text("Ask about any day…"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6).focused($focused)
                .onSubmit { send(draft) }
                .padding(.vertical, 9).padding(.leading, 12)
            if chat.busy {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11)).foregroundColor(Ink.onAccent).frame(width: 28, height: 28).background(Ink.accent).clipShape(Circle())
                }.buttonStyle(.plain).help(VL.text("Stop")).accessibilityLabel(VL.text("Stop"))
            } else {
                let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundColor(Ink.onAccent).frame(width: 28, height: 28).background(Ink.accent).clipShape(Circle())
                }.buttonStyle(.plain).disabled(empty).opacity(empty ? 0.4 : 1).keyboardShortcut(.return, modifiers: .command)
                    .help(VL.text("Send")).accessibilityLabel(VL.text("Send"))
            }
        }.padding(.trailing, 6).padding(.vertical, 3)
            .frame(maxWidth: 820).background(Ink.surface).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Ink.accent.opacity(0.6) : Ink.border, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func send(_ text: String) {
        guard !chat.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.ask(text, reviewFolder: reviewFolder)
        draft = ""
    }
}
