import CryptoKit
import Darwin
import Foundation

/// Only definitions live here. Requests, audio and results belong to their
/// existing stores and are never removed by catalog operations.
final class VectaSummaryFormatStore {
    private struct Entry: Codable {
        var format: VectaSummaryInterpretation
        let createdAt: Date
        var deletedAt: Date?
    }

    private struct Document: Codable {
        let version: Int
        var entries: [Entry]
    }

    private static let processLock = NSLock()
    private let stateLock = NSLock()
    private let directory: URL
    private let file: URL
    private var document = Document(version: 1, entries: [])

    init(userID: String, directory base: URL? = nil) throws {
        guard !userID.isEmpty else { throw VectaSummaryFormatError.invalidCatalog }
        let base = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vecta", isDirectory: true)
        let user = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = base.appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent(user, isDirectory: true).appendingPathComponent("SummaryFormats", isDirectory: true)
        file = directory.appendingPathComponent("formats.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw VectaSummaryFormatError.invalidCatalog }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch let error as VectaSummaryFormatError {
            throw error
        } catch {
            throw VectaSummaryFormatError.persistenceFailed
        }
        try withExclusiveAccess {
            if !Self.exists(file) {
                let now = Date()
                let initial = Document(version: 1, entries: VectaSummaryInterpretation.allCases.map {
                    Entry(format: $0, createdAt: now, deletedAt: nil)
                })
                try write(initial)
            }
            var current=try read()
            var changed=false
            // Update only the exact untouched shipped prompt. User edits and
            // historical request snapshots retain their original definition.
            for index in current.entries.indices where current.entries[index].format.id=="brief" && current.entries[index].format.revision==1 && current.entries[index].format.prompt==VectaSummaryInterpretation.legacyBriefPrompt {
                current.entries[index].format = .brief; changed=true
            }
            let revisions: [(VectaSummaryInterpretation, VectaSummaryInterpretation)] = [
                (.legacyDetailed, .detailed), (.legacyActionPlan, .actionPlan),
                (.legacyAnalytical, .analytical), (.legacyNlp, .nlp)]
            for index in current.entries.indices {
                if let update = revisions.first(where: { $0.0 == current.entries[index].format }), current.entries[index].deletedAt == nil {
                    current.entries[index].format = update.1; changed = true
                }
            }
            for format in [VectaSummaryInterpretation.standard,.analytical] where !current.entries.contains(where:{$0.format.id==format.id}) {
                current.entries.append(Entry(format:format,createdAt:Date(),deletedAt:nil))
                changed=true
            }
            if changed { try write(current) }
            replaceState(current)
        }
    }

    var all: [VectaSummaryInterpretation] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ordered(document.entries.filter { $0.deletedAt == nil }).map(\.format)
    }

    func reload() throws {
        try withExclusiveAccess { replaceState(try read()) }
    }

    @discardableResult
    func create(title: String, prompt: String) throws -> VectaSummaryInterpretation {
        let format = VectaSummaryInterpretation(id: "custom_" + UUID().uuidString.lowercased(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: Self.normalizedPrompt(prompt), revision: 1)
        guard format.isValid else { throw VectaSummaryFormatError.invalidDefinition }
        return try mutate { document in
            guard document.entries.count < 200 else { throw VectaSummaryFormatError.catalogFull }
            document.entries.append(Entry(format: format, createdAt: Date(), deletedAt: nil))
            return format
        }
    }

    @discardableResult
    func update(id: String, title: String, prompt: String, expectedRevision: Int) throws -> VectaSummaryInterpretation {
        try mutate { document in
            let index = try Self.index(id, expectedRevision: expectedRevision, deleted: false, in: document)
            let previous = document.entries[index].format
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = Self.normalizedPrompt(prompt)
            if previous.title == title && previous.prompt == prompt { return previous }
            let updated = VectaSummaryInterpretation(id: id, title: title, prompt: prompt, revision: previous.revision + 1)
            guard updated.isValid else { throw VectaSummaryFormatError.invalidDefinition }
            document.entries[index].format = updated
            return updated
        }
    }

    @discardableResult
    func delete(id: String, expectedRevision: Int) throws -> VectaSummaryInterpretation {
        try mutate { document in
            let index = try Self.index(id, expectedRevision: expectedRevision, deleted: false, in: document)
            let previous = document.entries[index].format
            guard !previous.isBuiltin else { throw VectaSummaryFormatError.invalidDefinition }
            let deleted = VectaSummaryInterpretation(id: id, title: previous.title, prompt: previous.prompt,
                                                   revision: previous.revision + 1)
            guard deleted.isValid else { throw VectaSummaryFormatError.invalidDefinition }
            document.entries.remove(at: index)
            return deleted
        }
    }

    private static func normalizedPrompt(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func index(_ id: String, expectedRevision: Int, deleted: Bool, in document: Document) throws -> Int {
        guard let index = document.entries.firstIndex(where: { $0.format.id == id }) else { throw VectaSummaryFormatError.missing }
        let entry = document.entries[index]
        guard expectedRevision == entry.format.revision, (entry.deletedAt != nil) == deleted else {
            throw VectaSummaryFormatError.changedElsewhere
        }
        return index
    }

    private func ordered(_ entries: [Entry]) -> [Entry] {
        let builtinOrder = VectaSummaryInterpretation.allCases.map(\.id)
        return entries.sorted {
            let left = builtinOrder.firstIndex(of: $0.format.id), right = builtinOrder.firstIndex(of: $1.format.id)
            if let left, let right { return left < right }
            if left != nil { return true }
            if right != nil { return false }
            return $0.createdAt == $1.createdAt ? $0.format.id < $1.format.id : $0.createdAt < $1.createdAt
        }
    }

    private func replaceState(_ value: Document) {
        stateLock.lock()
        document = value
        stateLock.unlock()
    }

    private func mutate(_ operation: (inout Document) throws -> VectaSummaryInterpretation) throws -> VectaSummaryInterpretation {
        try withExclusiveAccess {
            var latest = try read()
            do {
                let result = try operation(&latest)
                try write(latest)
                replaceState(latest)
                return result
            } catch {
                // A rejected stale editor still receives the newest catalog.
                replaceState(try read())
                throw error
            }
        }
    }

    private func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let descriptor = open(directory.appendingPathComponent(".catalog.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VectaSummaryFormatError.persistenceFailed }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(descriptor, LOCK_EX) == 0 else { throw VectaSummaryFormatError.persistenceFailed }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func read() throws -> Document {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw VectaSummaryFormatError.invalidCatalog }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size > 0, attributes.st_size <= 4 * 1_024 * 1_024,
              let data = try? input.read(upToCount: 4 * 1_024 * 1_024 + 1), data.count <= 4 * 1_024 * 1_024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = raw["entries"] as? [[String: Any]], !entries.isEmpty, entries.count <= 200,
              entries.allSatisfy({ VectaSummaryInterpretation.decodeSnapshot($0["format"]) != nil }) else {
            throw VectaSummaryFormatError.invalidCatalog
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Document.self, from: data), value.version == 1,
              Set(value.entries.map { $0.format.id }).count == value.entries.count,
              // V1 catalogs predate standard/analytical. Validate the original
              // mandatory definitions first so init can add the new formats.
              VectaSummaryInterpretation.allCases.filter({ !["standard","analytical"].contains($0.id) }).allSatisfy({ builtin in
                  value.entries.contains { $0.format.id == builtin.id }
              }) else { throw VectaSummaryFormatError.invalidCatalog }
        return value
    }

    private func write(_ value: Document) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4 * 1_024 * 1_024 else { throw VectaSummaryFormatError.catalogFull }
        let temporary = directory.appendingPathComponent(".formats-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VectaSummaryFormatError.persistenceFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            defer { try? output.close() }
            try output.write(contentsOf: data)
            try output.synchronize()
            try output.close()
            guard rename(temporary.path, file.path) == 0 else { throw VectaSummaryFormatError.persistenceFailed }
        } catch { throw VectaSummaryFormatError.persistenceFailed }
    }

    private static func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }
}

enum VectaSummaryFormatError: LocalizedError {
    case invalidDefinition, invalidCatalog, catalogFull, missing, changedElsewhere, persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidDefinition: return VL.text("Укажите название до 120 символов и инструкцию до 12 000 символов. Пустые поля не сохраняются.")
        case .invalidCatalog: return VL.text("Не удалось прочитать сохранённые форматы. Существующий файл оставлен без изменений.")
        case .catalogFull: return VL.text("Каталог форматов заполнен.")
        case .missing: return VL.text("Этот формат больше не найден. Обновите список.")
        case .changedElsewhere: return VL.text("Формат уже изменён в другом окне. Откройте его снова, чтобы сохранить новую версию.")
        case .persistenceFailed: return VL.text("Не удалось сохранить форматы на Mac. Проверьте свободное место и повторите.")
        }
    }
}
