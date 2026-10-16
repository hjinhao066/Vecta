import Foundation

protocol LocalModelDownloading: Sendable {
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws
}

/// One explicit file download. No inference path creates this object.
final class LocalModelDownloader: NSObject, URLSessionDownloadDelegate, LocalModelDownloading, @unchecked Sendable {
    static let rangeThreshold: Int64 = 32 * 1_048_576
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let retryDelay: UInt64
    private let threshold: Int64
    private let rangeSize: Int64
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var destination: URL?
    private var expectedRange: String?
    private var expectedBytes: Int64 = 0
    private var progress: ((Int64) -> Void)?

    // Configuration/range sizes are injectable for isolated URLProtocol fixtures.
    init(configuration: URLSessionConfiguration = .ephemeral, retryDelay: UInt64 = 1_000_000_000,
         threshold: Int64 = LocalModelDownloader.rangeThreshold, rangeSize: Int64 = 8 * 1_048_576) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.retryDelay = retryDelay; self.threshold = threshold; self.rangeSize = rangeSize
    }

    func download(_ file: LocalModelFile, to destination: URL,
                  progress: @escaping (Int64) -> Void) async throws {
        defer { close() }
        if file.size >= threshold {
            var offset: Int64 = 0
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LocalModelError.incomplete }
                offset = Int64(values.fileSize ?? 0)
                guard offset >= 0, offset <= file.size else { throw LocalModelError.incomplete }
            } else {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LocalModelError.incomplete }
            }
            let output = try FileHandle(forWritingTo: destination)
            try output.seekToEnd()
            defer { try? output.close() }
            // Reuse four sessions across batches and retries, instead of paying
            // for a new CDN/TLS connection for every range. Speech weights also
            // use bounded ranges; this is unrelated to PLAUD transfer/resume.
            let workers = (0..<4).map { _ in LocalModelDownloader(configuration: configuration, retryDelay: retryDelay) }
            defer { for worker in workers { worker.close() } }
            progress(offset)
            while offset < file.size {
                try Task.checkCancellation()
                let batchStart = offset
                let ranges = (0..<4).compactMap { index -> (Int64, Int64)? in
                    let start = batchStart + Int64(index) * rangeSize
                    return start < file.size ? (start, min(rangeSize, file.size - start)) : nil
                }
                let temporary = ranges.map { _ in destination.appendingPathExtension(UUID().uuidString + ".chunk") }
                defer { for path in temporary { try? FileManager.default.removeItem(at: path) } }
                let aggregate = LocalRangeProgress(initial: batchStart, slots: ranges.count, progress: progress)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (index, range) in ranges.enumerated() {
                        let chunk = temporary[index], worker = workers[index]
                        group.addTask {
                            var request = URLRequest(url: file.url)
                            request.setValue("bytes=\(range.0)-\(range.0 + range.1 - 1)", forHTTPHeaderField: "Range")
                            try await worker.requestWithRetry(request, bytes: range.1,
                                range: "bytes \(range.0)-\(range.0 + range.1 - 1)/\(file.size)", to: chunk) { aggregate.update(index, $0) }
                        }
                    }
                    try await group.waitForAll()
                }
                // Roll back an interrupted append to the last complete batch;
                // a resumed file must never contain an unaccounted partial range.
                do {
                    for chunk in temporary {
                        let input = try FileHandle(forReadingFrom: chunk)
                        defer { try? input.close() }
                        while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
                            try Task.checkCancellation()
                            try output.write(contentsOf: block)
                        }
                    }
                    try output.synchronize()
                } catch {
                    try? output.truncate(atOffset: UInt64(batchStart))
                    throw error
                }
                offset += ranges.reduce(0) { $0 + $1.1 }
            }
        } else {
            try await requestWithRetry(URLRequest(url: file.url), bytes: file.size, range: nil, to: destination, progress: progress)
        }
    }

    static func shouldRetry(_ error: Error) -> Bool {
        if let response = error as? LocalDownloadHTTPError { return [408, 429, 500, 502, 503, 504].contains(response.status) }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        // A transient TLS handshake can be retried with normal system trust.
        // Certificate/date/hostname/untrusted-root errors are never bypassed.
        return [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed].contains { $0.rawValue == error.code }
    }

    private func requestWithRetry(_ request: URLRequest, bytes: Int64, range: String?, to destination: URL,
                                  progress: @escaping (Int64) -> Void) async throws {
        var highWater: Int64 = 0
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                try await downloadRequest(request, bytes: bytes, range: range, to: destination) { count in
                    highWater = max(highWater, count); progress(highWater)
                }
                return
            } catch {
                try Task.checkCancellation()
                guard attempt < 3, Self.shouldRetry(error) else { throw error }
                try await Task.sleep(nanoseconds: retryDelay * UInt64(1 << attempt))
            }
        }
    }

    private func downloadRequest(_ original: URLRequest, bytes: Int64, range: String?, to destination: URL,
                                 progress: @escaping (Int64) -> Void) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.destination = destination
                self.progress = progress
                expectedBytes = bytes
                expectedRange = range
                let session: URLSession
                if let existing = self.session { session = existing }
                else {
                    let config = configuration.copy() as! URLSessionConfiguration
                    config.urlCache = nil; config.httpCookieStorage = nil
                    config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    config.timeoutIntervalForRequest = 60
                    config.timeoutIntervalForResource = 15 * 60
                    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session
                }
                var request = original
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    private func close() {
        lock.lock(); let session = session; self.session = nil; lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // CDN host changes are expected, but HTTPS must hold at every hop.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        guard task?.taskIdentifier == downloadTask.taskIdentifier else { lock.unlock(); return }
        let callback = progress, bound = expectedBytes, expectedStatus = expectedRange == nil ? 200 : 206
        lock.unlock()
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != expectedStatus {
            downloadTask.cancel(); finish(downloadTask, .failure(LocalDownloadHTTPError(status: response.statusCode))); return
        }
        callback?(min(totalBytesWritten, bound))
        if totalBytesWritten > bound { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            lock.lock()
            guard task?.taskIdentifier == downloadTask.taskIdentifier else { lock.unlock(); return }
            let destination = destination, cancelled = cancelled, expectedRange = expectedRange, expectedBytes = expectedBytes
            lock.unlock()
            guard !cancelled else { throw CancellationError() }
            guard let response = downloadTask.response as? HTTPURLResponse, response.url?.scheme == "https", let destination
            else { throw LocalModelError.invalidResponse }
            guard response.statusCode == (expectedRange == nil ? 200 : 206) else {
                throw LocalDownloadHTTPError(status: response.statusCode)
            }
            if let expectedRange, response.value(forHTTPHeaderField: "Content-Range") != expectedRange { throw LocalModelError.invalidResponse }
            let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
            guard size?.int64Value == expectedBytes else { throw LocalModelError.incomplete }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            finish(downloadTask, .success(()))
        } catch { finish(downloadTask, .failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock(); let cancelled = cancelled; lock.unlock()
            finish(task, .failure(cancelled ? CancellationError() : error))
        }
    }

    private func finish(_ completed: URLSessionTask, _ result: Result<Void, Error>) {
        lock.lock()
        guard task?.taskIdentifier == completed.taskIdentifier else { lock.unlock(); return }
        let continuation = continuation
        self.continuation = nil; task = nil; progress = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct LocalDownloadHTTPError: Error, LocalizedError {
    let status: Int
    var errorDescription: String? { VL.text("Сервер загрузки модели вернул HTTP \(status). Повторите загрузку позже.") }
}

/// Call progress under one lock so concurrent delegates cannot publish a
/// decreasing byte count. A new aggregate is created for each complete batch.
private final class LocalRangeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: Int64
    private var received: [Int64]
    private let progress: (Int64) -> Void
    init(initial: Int64, slots: Int, progress: @escaping (Int64) -> Void) {
        self.initial = initial; received = Array(repeating: 0, count: slots); self.progress = progress
    }
    func update(_ index: Int, _ count: Int64) {
        lock.lock(); defer { lock.unlock() }
        received[index] = max(received[index], count)
        progress(initial + received.reduce(0, +))
    }
}
