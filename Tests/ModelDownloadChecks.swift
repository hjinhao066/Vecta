import Foundation
import CryptoKit

// Test-only legacy boundary: these fixtures must never discover owner models.
enum VectaLegacyPaths {
    static func modelDirectory(name: String, preferred: URL) -> URL { preferred }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests = 0
    static var active = 0
    static var maximumActive = 0
    static var failure: URLError.Code?
    static var httpFailure = false
    static var badRange = false
    static var delay: TimeInterval = 0.02
    static let bytes = Data((0..<96).map(UInt8.init))
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "model-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func reset(failure: URLError.Code? = nil, httpFailure: Bool = false, badRange: Bool = false, delay: TimeInterval = 0.02) {
        lock.lock(); defer { lock.unlock() }
        requests = 0; active = 0; maximumActive = 0
        self.failure = failure; self.httpFailure = httpFailure; self.badRange = badRange; self.delay = delay
    }
    static var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (requests, maximumActive) }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1; Self.active += 1; Self.maximumActive = max(Self.active, Self.maximumActive)
        let number = Self.requests, failure = Self.failure, httpFailure = Self.httpFailure, badRange = Self.badRange, delay = Self.delay
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            stateLock.lock(); defer { stateLock.unlock() }
            guard !stopped else { return }
            Self.lock.lock(); Self.active -= 1; Self.lock.unlock()
            if number == 1, let failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
            let range = request.value(forHTTPHeaderField: "Range")
            let parts = range?.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
            let start = parts?.first ?? 0, end = parts?.last ?? (Self.bytes.count - 1)
            let data = Self.bytes.subdata(in: start..<(end + 1))
            var headers = ["Content-Length": String(data.count)]
            if range != nil { headers["Content-Range"] = badRange ? "bytes 0-1/2" : "bytes \(start)-\(end)/\(Self.bytes.count)" }
            let response = HTTPURLResponse(url: request.url!, statusCode: number == 1 && httpFailure ? 503 : (range == nil ? 200 : 206), httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

private actor InstallGate {
    var started = Set<String>()
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait(_ name: String) async {
        started.insert(name)
        if started.count == 3 { for waiter in waiters { waiter.resume() }; waiters.removeAll(); return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
private struct FixtureDownloader: LocalModelDownloading {
    let gate: InstallGate
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        await gate.wait(file.url.pathComponents[1])
        try Task.checkCancellation()
        try ModelURLProtocol.bytes.write(to: destination)
        progress(file.size)
    }
}

@main private struct ModelDownloadChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "ModelDownloadChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VectaModelChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = SHA256.hash(data: ModelURLProtocol.bytes).map { String(format: "%02x", $0) }.joined()
        let file = LocalModelFile(name: "fixture.bin", url: URL(string: "https://model-fixture.invalid/fixture.bin")!, sha256: hash, size: Int64(ModelURLProtocol.bytes.count))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelURLProtocol.self]
        func downloader(ranges: Bool = false) -> LocalModelDownloader {
            LocalModelDownloader(configuration: config, retryDelay: 1_000_000, threshold: ranges ? 1 : 1_000, rangeSize: 8)
        }
        var sequence = 0
        func target() -> URL { sequence += 1; return root.appendingPathComponent("file-\(sequence)") }
        ModelURLProtocol.reset(failure: .secureConnectionFailed)
        let tls = target(); try await downloader().download(file, to: tls) { _ in }
        try LocalModelIntegrity.verify(file, at: tls)
        try check(ModelURLProtocol.counts.0 == 2, "Transient TLS handshake must retry without weakening system trust")
        ModelURLProtocol.reset(failure: .serverCertificateUntrusted)
        do { try await downloader().download(file, to: target()) { _ in }; preconditionFailure("Untrusted certificate accepted") }
        catch { try check(ModelURLProtocol.counts.0 == 1 && !LocalModelDownloader.shouldRetry(error), "Certificate failures must not retry or bypass trust") }
        for code in [URLError.serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .cancelled] {
            try check(!LocalModelDownloader.shouldRetry(URLError(code)), "Non-transient TLS/cancel error classified as retryable")
        }
        ModelURLProtocol.reset(httpFailure: true)
        let http = target(); try await downloader().download(file, to: http) { _ in }
        try check(ModelURLProtocol.counts.0 == 2, "HTTP503 must retry")
        ModelURLProtocol.reset()
        let ranged = target(); try await downloader(ranges: true).download(file, to: ranged) { _ in }
        try LocalModelIntegrity.verify(file, at: ranged)
        try check(ModelURLProtocol.counts.1 > 1 && ModelURLProtocol.counts.1 <= 4, "Ranges must overlap, bounded to four requests")
        try check(ModelURLProtocol.counts.0 == 12, "All strict ranges across three batches must arrive")
        ModelURLProtocol.reset()
        let resumed = target(); try ModelURLProtocol.bytes.prefix(11).write(to: resumed)
        try await downloader(ranges: true).download(file, to: resumed) { _ in }
        try LocalModelIntegrity.verify(file, at: resumed)
        try check(ModelURLProtocol.counts.0 == 11, "Resume must preserve the exact existing prefix")
        ModelURLProtocol.reset(badRange: true)
        let invalid = target()
        do { try await downloader(ranges: true).download(file, to: invalid) { _ in }; preconditionFailure("Bad Content-Range accepted") }
        catch { let contents = try Data(contentsOf: invalid); try check(contents.isEmpty, "No unverified ranges may be appended") }
        ModelURLProtocol.reset(delay: 2)
        let cancelled = Task { try await downloader().download(file, to: target()) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000); cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch { try check(error is CancellationError, "Cancellation must propagate, not retry") }
        try check(ModelURLProtocol.counts.0 == 1, "Cancelled download was retried")

        let revision = String(repeating: "a", count: 40)
        let definitions = LocalModelManager.speechIDs.map { id in
            LocalModelDefinition(id: id, title: id, variant: "fixture", repository: id + "/fixture", revision: revision, license: "MIT", files: [LocalModelFile(name: "fixture.bin", url: URL(string: "https://huggingface.co/\(id)/fixture/resolve/\(revision)/\(id == "whisper" ? "openai_whisper-large-v3-v20240930_turbo_632MB/" : "")fixture.bin")!, sha256: hash, size: file.size)])
        }
        let gate = InstallGate(), modelRoot = root.appendingPathComponent("Models")
        let manager = try LocalModelManager(registry: LocalModelRegistry(version: 1, models: definitions), root: modelRoot, makeDownloader: { FixtureDownloader(gate: gate) }, freeSpace: { _ in 2_000_000_000 })
        try await manager.installSpeech { _ in }
        let started = await gate.started
        try check(started.count == 3, "All speech components must download concurrently")
        let acquired = try await manager.acquire("whisper")
        do { try await manager.remove("whisper"); preconditionFailure("Deleted a model in use") }
        catch { try check(FileManager.default.fileExists(atPath: acquired.path), "In-use models must be preserved") }
        await manager.release("whisper")
        let partial = modelRoot.appendingPathComponent(".install-whisper-" + revision)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try Data([1, 2]).write(to: partial.appendingPathComponent("partial.bin"))
        try await manager.remove("whisper")
        try check(!FileManager.default.fileExists(atPath: acquired.path) && !FileManager.default.fileExists(atPath: partial.path), "Removal must delete installed and partial model files")
        _ = try await manager.verify("speaker")
        try check(FileManager.default.fileExists(atPath: root.path), "Deletion escaped model paths")
        print("PASS \(checks) model-download checks: transient TLS/HTTP retries, certificate rejection, cancellation, four-way exact ranges, resume, malformed range rejection, parallel speech install, in-use protection and partial deletion. Synthetic URLProtocol/files only; no model weights, network, owner data or inference.")
    }
}
