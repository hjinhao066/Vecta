import Foundation

protocol LocalModelDownloading: Sendable {
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws
}

/// One explicit file download. No inference path creates this object.
final class LocalModelDownloader: NSObject, URLSessionDownloadDelegate, LocalModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var destination: URL?
    private var expectedRange: String?
    private var expectedBytes: Int64 = 0
    private var progress: ((Int64) -> Void)?

    func download(_ file: LocalModelFile, to destination: URL,
                  progress: @escaping (Int64) -> Void) async throws {
        // Some model CDNs throttle a single multi-GB response. Bounded Range
        // requests retain exact pinned bytes and require a verified Content-Range.
        // This is model download only, not PLAUD download/resume transport.
        if file.size >= 1_100_000_000 {
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
            progress(offset)
            // Four independent, validated ranges bound disk/memory usage and
            // avoid a slow single CDN response. Append only complete batches,
            // in byte order; manager verifies the entire pinned SHA-256 later.
            while offset < file.size {
                try Task.checkCancellation()
                let batchStart = offset
                let ranges = (0..<4).compactMap { index -> (Int64, Int64)? in
                    let start = batchStart + Int64(index) * 4 * 1_048_576
                    return start < file.size ? (start, min(4 * 1_048_576, file.size - start)) : nil
                }
                let temporary = ranges.map { _ in destination.appendingPathExtension(UUID().uuidString + ".chunk") }
                defer { for path in temporary { try? FileManager.default.removeItem(at: path) } }
                let aggregate = LocalRangeProgress(initial: batchStart, slots: ranges.count, progress: progress)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (index, range) in ranges.enumerated() {
                        let chunk = temporary[index]
                        group.addTask {
                            var request = URLRequest(url: file.url)
                            request.setValue("bytes=\(range.0)-\(range.0 + range.1 - 1)", forHTTPHeaderField: "Range")
                            let downloader = LocalModelDownloader()
                            try await downloader.downloadRequest(request, bytes: range.1,
                                range: "bytes \(range.0)-\(range.0 + range.1 - 1)/\(file.size)", to: chunk) { aggregate.update(index, $0) }
                        }
                    }
                    try await group.waitForAll()
                }
                for (index, range) in ranges.enumerated() {
                    let input = try FileHandle(forReadingFrom: temporary[index])
                    defer { try? input.close() }
                    while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
                        try Task.checkCancellation()
                        try output.write(contentsOf: block)
                    }
                    offset += range.1
                }
            }
            try output.synchronize()
        } else {
            try await downloadRequest(URLRequest(url: file.url), bytes: file.size, range: nil, to: destination, progress: progress)
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
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                config.httpCookieStorage = nil
                config.timeoutIntervalForRequest = 120
                config.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
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
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock(); let callback = progress; let bound = expectedBytes; lock.unlock()
        callback?(min(totalBytesWritten, bound))
        if totalBytesWritten > bound { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            lock.lock(); let destination = destination; let cancelled = cancelled; lock.unlock()
            guard !cancelled else { throw CancellationError() }
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == (expectedRange == nil ? 200 : 206), response.url?.scheme == "https", let destination
            else { throw LocalModelError.invalidResponse }
            if let expectedRange, response.value(forHTTPHeaderField: "Content-Range") != expectedRange { throw LocalModelError.invalidResponse }
            let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
            guard size?.int64Value == expectedBytes else { throw LocalModelError.incomplete }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(cancelled ? CancellationError() : error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
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
