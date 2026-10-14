import Foundation
import Darwin

/// A private, network-denied, framed worker owned by the existing host lease.
final class LocalAIWarmWorker {
    let modelID:String
    let eventURL:URL
    let process:Process
    private let input:FileHandle
    private let output:FileHandle
    private let diagnostic:FileHandle
    private let diagnosticURL:URL
    init(modelID:String,executable:URL,directory:URL,root:URL) throws {
        self.modelID=modelID
        let events=root.appendingPathComponent("LocalAI/WorkerEvents",isDirectory:true)
        try FileManager.default.createDirectory(at:events,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        eventURL=events.appendingPathComponent(UUID().uuidString+".json")
        diagnosticURL=events.appendingPathComponent(UUID().uuidString+".tmp")
        FileManager.default.createFile(atPath:diagnosticURL.path,contents:nil,attributes:[.posixPermissions:0o600])
        diagnostic=try FileHandle(forWritingTo:diagnosticURL)
        let incoming=Pipe(),outgoing=Pipe();input=incoming.fileHandleForWriting;output=outgoing.fileHandleForReading
        process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        process.arguments=["-p","(version 1)(allow default)(deny network*)",executable.path,directory.path,"",eventURL.path,"--serve-library"]
        process.qualityOfService = .utility
        process.environment=["PATH":"/usr/bin:/bin","HOME":FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput=incoming;process.standardOutput=outgoing;process.standardError=diagnostic
        try process.run()
    }
    func terminate() {
        if process.isRunning {process.terminate();let p=process;DispatchQueue.global().asyncAfter(deadline:.now()+3){if p.isRunning {Darwin.kill(p.processIdentifier,SIGKILL)}}}
    }
    func exchange(_ data:Data) async throws -> Data {
        guard process.isRunning,data.count<256_000 else {throw AIProcessingError.invalidRequest}
        let incoming=input,outgoing=output,p=process
        let timeout=Task {try? await Task.sleep(nanoseconds:180_000_000_000);if !Task.isCancelled {self.terminate()}}
        defer {timeout.cancel()}
        return try await withTaskCancellationHandler(operation:{
            try await Task.detached(priority:.utility) {
                try incoming.write(contentsOf:data+Data([10]))
                var response=Data()
                // Only one exchange is admitted by LocalAIHost. Read precisely one frame.
                var buffer=[UInt8](repeating:0,count:8192)
                while true {
                    // FileHandle.read(upToCount:) can wait to fill its buffer on a
                    // persistent pipe. POSIX read returns the available frame bytes.
                    let count=buffer.withUnsafeMutableBytes {Darwin.read(outgoing.fileDescriptor,$0.baseAddress,8192)}
                    if count<0 {if errno==EINTR {continue};throw AIProcessingError.interrupted}
                    if count==0 {break}
                    let chunk=Data(buffer.prefix(count))
                    if let end=chunk.firstIndex(of:10) {
                        // One response per admitted exchange; trailing data violates framing.
                        guard end==chunk.index(before:chunk.endIndex),response.count+end<128_000 else{throw AIProcessingError.invalidSummary}
                        response.append(chunk.prefix(upTo:end));return response
                    }
                    response.append(chunk);guard response.count<128_000 else {throw AIProcessingError.invalidSummary}
                }
                throw AIProcessingError.interrupted
            }.value
        },onCancel:{if p.isRunning {self.terminate()}})
    }
    func stop() async {
        terminate();let p=process
        await Task.detached(priority:.utility){p.waitUntilExit()}.value
        try? input.close();try? output.close();try? diagnostic.close()
        try? FileManager.default.removeItem(at:eventURL);try? FileManager.default.removeItem(at:diagnosticURL)
    }
}
