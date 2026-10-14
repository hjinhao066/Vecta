import CryptoKit
import Foundation

struct LocalModelFile: Codable, Equatable {
    let name: String
    let url: URL
    let sha256: String
    let size: Int64
}

struct LocalModelDefinition: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let variant: String
    let repository: String
    let revision: String
    let license: String
    let files: [LocalModelFile]
    var backend: String? = nil
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
    func validate() throws {
        guard ["whisper", "speaker", "tokenizer", "qwen4b", "qwen9b"].contains(id), revision.count == 40,
              revision.allSatisfy({ "0123456789abcdef".contains($0) }),
              !files.isEmpty, Set(files.map(\.name)).count == files.count,
              ["Apache-2.0", "MIT", "CC-BY-4.0"].contains(license) else { throw LocalModelError.invalidManifest }
        guard !["qwen4b", "qwen9b"].contains(id) || backend == "mlx" else { throw LocalModelError.invalidManifest }
        for file in files {
            guard !file.name.isEmpty, !file.name.hasPrefix("/"), !file.name.split(separator:"/",omittingEmptySubsequences:false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), !file.name.contains("\\"),
                  file.url.scheme == "https", file.url.host == "huggingface.co",
                  file.url.path == "/\(repository)/resolve/\(revision)/\(id == "whisper" ? "openai_whisper-large-v3-v20240930_turbo_632MB/" : "")\(file.name)",
                  file.url.query == nil, file.url.fragment == nil,
                  file.size > 0, file.size < 8_000_000_000,
                  file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
            else { throw LocalModelError.invalidManifest }
        }
    }
}

struct LocalModelRegistry: Codable {
    let version: Int
    let models: [LocalModelDefinition]
    static func load(from url: URL) throws -> Self {
        let registry = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard registry.version == 1, Set(registry.models.map(\.id)) == Set(["whisper", "speaker", "tokenizer", "qwen4b", "qwen9b"]),
              registry.models.count == 5 else { throw LocalModelError.invalidManifest }
        for model in registry.models { try model.validate() }
        return registry
    }
}

enum LocalModelState: String, Codable {
    case notInstalled, preparing, downloading, verifying, installed, damaged, failed, deleting
}

struct LocalModelStatus: Codable, Equatable {
    let modelID: String
    var state: LocalModelState
    var received: Int64
    let total: Int64
    var error: String?
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

enum LocalModelError: Error, LocalizedError {
    case invalidManifest, checksum(String), insufficientSpace, incomplete, inUse, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return VL.text("Некорректный каталог AI-моделей.")
        case .checksum(let file): return VL.text("Проверка целостности не пройдена: \(file).")
        case .insufficientSpace: return VL.text("Недостаточно свободного места для установки модели.")
        case .incomplete: return VL.text("Модель не установлена полностью.")
        case .inUse: return VL.text("Модель сейчас используется. Сначала отмените обработку.")
        case .invalidResponse: return VL.text("Сервер не передал выбранный файл модели.")
        }
    }
}

enum LocalModelIntegrity {
    /// Stream the file: model weights must never be copied into a giant Data.
    static func verify(_ file: LocalModelFile, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == file.size else { throw LocalModelError.checksum(file.name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        // FileHandle bridges NSData. Drain each read's autoreleased objects
        // rather than retaining gigabytes until the actor's outer pool drains.
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data=try handle.read(upToCount:1_048_576),!data.isEmpty else {return false}
            digest.update(data:data)
            return true
        }) {}
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == file.sha256 else { throw LocalModelError.checksum(file.name) }
    }
}
