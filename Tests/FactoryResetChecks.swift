import CryptoKit
import Foundation

private final class FactoryResetExpectationCapture: FactoryResetBackupExpectationSink {
    private let fail: Bool
    private(set) var expectation: FactoryResetBackupExpectation?
    private(set) var attempts = 0

    init(fail: Bool = false) {
        self.fail = fail
    }

    func retain(_ expectation: FactoryResetBackupExpectation) throws {
        attempts += 1
        guard !fail else { throw FactoryResetBackupPublicationError.expectationNotRetained }
        self.expectation = expectation
    }
}

enum FactoryResetChecks {
    static func run(root: URL) throws {
        let inventory = [ProtocolRecordingFile(sessionID: 7, byteSize: 3, scene: 2, attribute: 1)]
        let payload = Data([1, 2, 3])
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        func manifest(serialNumber: String = "882-fixture", model: String = "notepins", protocolVersion: UInt16 = 20, inventory: [ProtocolRecordingFile] = inventory, artifacts: [FactoryResetBackupArtifact]) -> FactoryResetBackupManifest {
            FactoryResetBackupManifest(serialNumber: serialNumber, model: model, protocolVersion: protocolVersion,
                                       recorderInventory: inventory, artifacts: artifacts)
        }

        func manifestData(_ manifest: FactoryResetBackupManifest) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(manifest)
        }

        func expectation(_ manifest: FactoryResetBackupManifest, serialNumber: String? = nil, model: String? = nil, protocolVersion: UInt16? = nil, inventory: [ProtocolRecordingFile]? = nil) throws -> FactoryResetBackupExpectation {
            let data = try manifestData(manifest)
            return FactoryResetBackupExpectation(serialNumber: serialNumber ?? manifest.serialNumber,
                                                 model: model ?? manifest.model,
                                                 protocolVersion: protocolVersion ?? manifest.protocolVersion,
                                                 recorderInventory: inventory ?? manifest.recorderInventory,
                                                 manifestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }

        func writeBackup(_ name: String, manifest: FactoryResetBackupManifest, files: [String: Data]) throws -> URL {
            let backup = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            for (path, data) in files {
                let url = backup.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try manifestData(manifest).write(to: backup.appendingPathComponent("manifest.json"))
            return backup
        }

        let artifact = FactoryResetBackupArtifact(sessionID: 7, path: "recordings/7.plaudaudio", sha256: digest, bytes: 3)
        let validManifest = manifest(artifacts: [artifact])
        let validExpectation = try expectation(validManifest)
        let valid = try writeBackup("valid", manifest: validManifest, files: [artifact.path: payload])
        try FactoryResetBackupVerifier.verify(backupRoot: valid, expectation: validExpectation)
        try CoreChecks.check(true, "Exact factory-reset backup was rejected")

        let alteredManifest = manifest(artifacts: [artifact])
        let altered = try writeBackup("altered", manifest: alteredManifest, files: [artifact.path: Data([1, 2, 4])])
        try CoreChecks.rejects("Changed backup bytes accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: altered, expectation: try expectation(alteredManifest))
        }

        let forgedData = Data([9, 8, 7])
        let forgedDigest = SHA256.hash(data: forgedData).map { String(format: "%02x", $0) }.joined()
        let forgedArtifact = FactoryResetBackupArtifact(sessionID: 7, path: artifact.path, sha256: forgedDigest, bytes: 3)
        let forgedManifest = manifest(artifacts: [forgedArtifact])
        let forged = try writeBackup("forged", manifest: forgedManifest, files: [forgedArtifact.path: forgedData])
        try CoreChecks.rejects("Self-authored forged manifest accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: forged, expectation: validExpectation)
        }

        let extraManifest = manifest(artifacts: [artifact])
        let extra = try writeBackup("extra", manifest: extraManifest, files: [artifact.path: payload, "unexpected.bin": Data([9])])
        try CoreChecks.rejects("Unmanifested backup file accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: extra, expectation: try expectation(extraManifest))
        }

        let traversalManifest = manifest(artifacts: [FactoryResetBackupArtifact(sessionID: 7, path: "../escape", sha256: digest, bytes: 3)])
        let traversal = try writeBackup("traversal", manifest: traversalManifest, files: [:])
        try CoreChecks.rejects("Traversal backup path accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: traversal, expectation: try expectation(traversalManifest))
        }

        let missingManifest = manifest(artifacts: [artifact])
        let missing = try writeBackup("missing", manifest: missingManifest, files: [:])
        try CoreChecks.rejects("Missing backup artifact accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: missing, expectation: try expectation(missingManifest))
        }

        let duplicateInventoryManifest = manifest(inventory: [inventory[0], inventory[0]], artifacts: [artifact])
        let duplicateInventory = try writeBackup("duplicate-inventory", manifest: duplicateInventoryManifest, files: [artifact.path: payload])
        try CoreChecks.rejects("Duplicate session inventory accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: duplicateInventory, expectation: try expectation(duplicateInventoryManifest))
        }

        let duplicateArtifactsManifest = manifest(artifacts: [artifact, FactoryResetBackupArtifact(sessionID: 7, path: "recordings/7-copy.plaudaudio", sha256: digest, bytes: 3)])
        let duplicateArtifacts = try writeBackup("duplicate-artifacts", manifest: duplicateArtifactsManifest, files: [artifact.path: payload, "recordings/7-copy.plaudaudio": payload])
        try CoreChecks.rejects("Duplicate session artifacts accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: duplicateArtifacts, expectation: try expectation(duplicateArtifactsManifest))
        }

        let metadataMismatch = [ProtocolRecordingFile(sessionID: 7, byteSize: 3, scene: 3, attribute: 1)]
        try CoreChecks.rejects("Changed recorder metadata accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: valid, expectation: try expectation(validManifest, inventory: metadataMismatch))
        }

        try CoreChecks.rejects("Wrong device identity accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: valid, expectation: try expectation(validManifest, serialNumber: "882-other"))
        }

        let symlinkManifest = manifest(artifacts: [artifact])
        let symlink = try writeBackup("symlink", manifest: symlinkManifest, files: [:])
        let external = root.appendingPathComponent("outside.plaudaudio")
        try payload.write(to: external)
        try FileManager.default.createDirectory(at: symlink.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink.appendingPathComponent(artifact.path), withDestinationURL: external)
        try CoreChecks.rejects("Symlinked backup artifact accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: symlink, expectation: try expectation(symlinkManifest))
        }

        let linkedRoot = root.appendingPathComponent("valid-link")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: valid)
        try CoreChecks.rejects("Symlinked backup root accepted") {
            try FactoryResetBackupVerifier.verify(backupRoot: linkedRoot, expectation: validExpectation)
        }

        let raw = root.appendingPathComponent("raw/7.plaudaudio")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: raw)
        let publicationDestination = root.appendingPathComponent("publisher-destination")
        try FileManager.default.createDirectory(at: publicationDestination, withIntermediateDirectories: true)
        let snapshot = FactoryResetBackupSnapshot(serialNumber: "882-fixture", model: "notepins",
                                                  protocolVersion: 20, recorderInventory: inventory)
        let sink = FactoryResetExpectationCapture()
        let publication = try FactoryResetBackupPublisher.publish(
            snapshot: snapshot,
            rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
            selectedDestination: publicationDestination,
            expectationSink: sink
        )
        try CoreChecks.check(sink.expectation == publication.expectation, "Publisher did not retain the external expectation")
        try FactoryResetBackupVerifier.verify(backupRoot: publication.backupRoot, expectation: publication.expectation)
        try CoreChecks.check(Data(contentsOf: raw) == payload, "Publisher changed the raw transfer staging file")

        let failingSink = FactoryResetExpectationCapture(fail: true)
        try CoreChecks.rejects("Publisher returned success when external expectation retention failed") {
            _ = try FactoryResetBackupPublisher.publish(
                snapshot: snapshot,
                rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
                selectedDestination: publicationDestination,
                expectationSink: failingSink
            )
        }
        try CoreChecks.check(failingSink.attempts == 1, "Publisher skipped expectation retention")

        let visiblePublicationsBeforeCancellation = try FileManager.default.contentsOfDirectory(atPath: publicationDestination.path)
            .filter { $0.hasPrefix("Vecta-reset-backup-") }
        var cancellationChecks = 0
        try CoreChecks.rejects("Cancelled publisher completed") {
            _ = try FactoryResetBackupPublisher.publish(
                snapshot: snapshot,
                rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
                selectedDestination: publicationDestination,
                expectationSink: FactoryResetExpectationCapture(),
                shouldCancel: {
                    cancellationChecks += 1
                    return cancellationChecks >= 4
                }
            )
        }
        let visiblePublicationsAfterCancellation = try FileManager.default.contentsOfDirectory(atPath: publicationDestination.path)
            .filter { $0.hasPrefix("Vecta-reset-backup-") }
        try CoreChecks.check(visiblePublicationsAfterCancellation == visiblePublicationsBeforeCancellation,
                             "Cancelled publisher exposed a completed backup")

        let symlinkedDestination = root.appendingPathComponent("publisher-destination-link")
        try FileManager.default.createSymbolicLink(at: symlinkedDestination, withDestinationURL: publicationDestination)
        try CoreChecks.rejects("Publisher accepted a symlinked destination") {
            _ = try FactoryResetBackupPublisher.publish(
                snapshot: snapshot,
                rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
                selectedDestination: symlinkedDestination,
                expectationSink: FactoryResetExpectationCapture()
            )
        }

        let racedDestination = root.appendingPathComponent("publisher-race-destination")
        let movedDestination = root.appendingPathComponent("publisher-race-moved")
        let redirectedDestination = root.appendingPathComponent("publisher-race-redirected")
        try FileManager.default.createDirectory(at: racedDestination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirectedDestination, withIntermediateDirectories: true)
        var raceChecks = 0
        try CoreChecks.rejects("Publisher followed a replaced destination path") {
            _ = try FactoryResetBackupPublisher.publish(
                snapshot: snapshot,
                rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
                selectedDestination: racedDestination,
                expectationSink: FactoryResetExpectationCapture(),
                shouldCancel: {
                    raceChecks += 1
                    if raceChecks == 2 {
                        try! FileManager.default.moveItem(at: racedDestination, to: movedDestination)
                        try! FileManager.default.createSymbolicLink(at: racedDestination, withDestinationURL: redirectedDestination)
                    }
                    return false
                }
            )
        }
        try CoreChecks.check(try FileManager.default.contentsOfDirectory(atPath: redirectedDestination.path).isEmpty,
                             "Publisher wrote through a replaced destination path")

        var downloadedSessions: [UInt32] = []
        let coordinatorPublication = try FactoryResetBackupCoordinator.publish(
            freshSnapshot: { snapshot },
            downloadRaw: { suppliedSnapshot, recording in
                try CoreChecks.check(suppliedSnapshot == snapshot, "Coordinator changed the authenticated snapshot")
                downloadedSessions.append(recording.sessionID)
                return raw
            },
            revalidateSnapshot: { snapshot },
            selectedDestination: publicationDestination,
            expectationSink: FactoryResetExpectationCapture()
        )
        try CoreChecks.check(downloadedSessions == [7], "Coordinator did not request raw transfers sequentially")
        try FactoryResetBackupVerifier.verify(backupRoot: coordinatorPublication.backupRoot,
                                              expectation: coordinatorPublication.expectation)

        let changedSnapshot = FactoryResetBackupSnapshot(serialNumber: snapshot.serialNumber, model: snapshot.model,
                                                          protocolVersion: snapshot.protocolVersion,
                                                          recorderInventory: [ProtocolRecordingFile(sessionID: 7, byteSize: 3, scene: 9, attribute: 1)])
        try CoreChecks.rejects("Coordinator accepted a changed post-transfer inventory") {
            _ = try FactoryResetBackupCoordinator.publish(
                freshSnapshot: { snapshot },
                downloadRaw: { _, _ in raw },
                revalidateSnapshot: { changedSnapshot },
                selectedDestination: publicationDestination,
                expectationSink: FactoryResetExpectationCapture()
            )
        }

        var transferStarted = false
        try CoreChecks.rejects("Cancelled coordinator started a raw transfer") {
            _ = try FactoryResetBackupCoordinator.publish(
                freshSnapshot: { snapshot },
                downloadRaw: { _, _ in
                    transferStarted = true
                    return raw
                },
                revalidateSnapshot: { snapshot },
                selectedDestination: publicationDestination,
                expectationSink: FactoryResetExpectationCapture(),
                shouldCancel: { true }
            )
        }
        try CoreChecks.check(!transferStarted, "Cancelled coordinator invoked raw transfer")
    }
}
