import CryptoKit
import Foundation
import XCTest
@testable import NotePinTransport

final class FactoryResetBackupVerifierTests: XCTestCase {
    private final class ExpectationSink: FactoryResetBackupExpectationSink {
        private(set) var expectation: FactoryResetBackupExpectation?
        private let fails: Bool

        init(fails: Bool = false) {
            self.fails = fails
        }

        func retain(_ expectation: FactoryResetBackupExpectation) throws {
            guard !fails else { throw FactoryResetBackupPublicationError.expectationNotRetained }
            self.expectation = expectation
        }
    }

    private let inventory = [ProtocolRecordingFile(sessionID: 7, byteSize: 3, scene: 2, attribute: 1)]
    private let payload = Data([1, 2, 3])

    private func manifest(artifact: FactoryResetBackupArtifact) -> FactoryResetBackupManifest {
        FactoryResetBackupManifest(serialNumber: "882-fixture", model: "notepins", protocolVersion: 20,
                                   recorderInventory: inventory, artifacts: [artifact])
    }

    private func data(_ manifest: FactoryResetBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    private func expectation(_ manifest: FactoryResetBackupManifest, serialNumber: String? = nil) throws -> FactoryResetBackupExpectation {
        let digest = SHA256.hash(data: try data(manifest)).map { String(format: "%02x", $0) }.joined()
        return FactoryResetBackupExpectation(serialNumber: serialNumber ?? manifest.serialNumber,
                                             model: manifest.model,
                                             protocolVersion: manifest.protocolVersion,
                                             recorderInventory: manifest.recorderInventory,
                                             manifestSHA256: digest)
    }

    private func writeBackup(root: URL, manifest: FactoryResetBackupManifest, artifact: FactoryResetBackupArtifact, data: Data) throws {
        let artifactURL = root.appendingPathComponent(artifact.path)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: artifactURL)
        try self.data(manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    func testRequiresTrustedManifestDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-reset-verifier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let artifact = FactoryResetBackupArtifact(sessionID: 7, path: "recordings/7.plaudaudio", sha256: digest, bytes: 3)
        let valid = manifest(artifact: artifact)
        try writeBackup(root: root, manifest: valid, artifact: artifact, data: payload)
        try FactoryResetBackupVerifier.verify(backupRoot: root, expectation: try expectation(valid))

        let forgedData = Data([9, 8, 7])
        let forgedDigest = SHA256.hash(data: forgedData).map { String(format: "%02x", $0) }.joined()
        let forgedArtifact = FactoryResetBackupArtifact(sessionID: 7, path: artifact.path, sha256: forgedDigest, bytes: 3)
        let forged = manifest(artifact: forgedArtifact)
        try writeBackup(root: root, manifest: forged, artifact: forgedArtifact, data: forgedData)
        XCTAssertThrowsError(try FactoryResetBackupVerifier.verify(backupRoot: root, expectation: try expectation(valid)))
    }

    func testRejectsMismatchedDeviceAndSymlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-reset-verifier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let artifact = FactoryResetBackupArtifact(sessionID: 7, path: "recordings/7.plaudaudio", sha256: digest, bytes: 3)
        let manifest = manifest(artifact: artifact)
        try writeBackup(root: root, manifest: manifest, artifact: artifact, data: payload)
        XCTAssertThrowsError(try FactoryResetBackupVerifier.verify(backupRoot: root, expectation: try expectation(manifest, serialNumber: "882-other")))

        let parent = root.deletingLastPathComponent()
        let link = parent.appendingPathComponent(root.lastPathComponent + "-link")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try FactoryResetBackupVerifier.verify(backupRoot: link, expectation: try expectation(manifest)))
    }

    func testPublisherPublishesExactRawBackupBeforeRetainingExpectation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-reset-publisher-" + UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        let raw = root.appendingPathComponent("raw/7.plaudaudio")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try payload.write(to: raw)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = FactoryResetBackupSnapshot(serialNumber: "882-fixture", model: "notepins",
                                                  protocolVersion: 20, recorderInventory: inventory)
        let sink = ExpectationSink()
        let publication = try FactoryResetBackupPublisher.publish(
            snapshot: snapshot,
            rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
            selectedDestination: destination,
            expectationSink: sink
        )

        XCTAssertEqual(sink.expectation, publication.expectation)
        XCTAssertEqual(try Data(contentsOf: raw), payload)
        try FactoryResetBackupVerifier.verify(backupRoot: publication.backupRoot, expectation: publication.expectation)
    }

    func testCoordinatorRequiresUnchangedFreshInventory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-reset-coordinator-" + UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        let raw = root.appendingPathComponent("raw/7.plaudaudio")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try payload.write(to: raw)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = FactoryResetBackupSnapshot(serialNumber: "882-fixture", model: "notepins",
                                                  protocolVersion: 20, recorderInventory: inventory)
        var requested: [UInt32] = []
        let publication = try FactoryResetBackupCoordinator.publish(
            freshSnapshot: { snapshot },
            downloadRaw: { suppliedSnapshot, recording in
                XCTAssertEqual(suppliedSnapshot, snapshot)
                requested.append(recording.sessionID)
                return raw
            },
            revalidateSnapshot: { snapshot },
            selectedDestination: destination,
            expectationSink: ExpectationSink()
        )
        XCTAssertEqual(requested, [7])
        try FactoryResetBackupVerifier.verify(backupRoot: publication.backupRoot, expectation: publication.expectation)

        let changed = FactoryResetBackupSnapshot(serialNumber: snapshot.serialNumber, model: snapshot.model,
                                                 protocolVersion: snapshot.protocolVersion,
                                                 recorderInventory: [ProtocolRecordingFile(sessionID: 7, byteSize: 3, scene: 8, attribute: 1)])
        XCTAssertThrowsError(try FactoryResetBackupCoordinator.publish(
            freshSnapshot: { snapshot },
            downloadRaw: { _, _ in raw },
            revalidateSnapshot: { changed },
            selectedDestination: destination,
            expectationSink: ExpectationSink()
        )) { error in
            XCTAssertEqual(error as? FactoryResetBackupCoordinatorError, .inventoryChanged)
        }
    }

    func testPublisherRejectsDestinationReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-reset-publisher-" + UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        let movedDestination = root.appendingPathComponent("moved")
        let redirectedDestination = root.appendingPathComponent("redirected")
        let raw = root.appendingPathComponent("raw/7.plaudaudio")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirectedDestination, withIntermediateDirectories: true)
        try payload.write(to: raw)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = FactoryResetBackupSnapshot(serialNumber: "882-fixture", model: "notepins",
                                                  protocolVersion: 20, recorderInventory: inventory)
        var checks = 0
        XCTAssertThrowsError(try FactoryResetBackupPublisher.publish(
            snapshot: snapshot,
            rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
            selectedDestination: destination,
            expectationSink: ExpectationSink(),
            shouldCancel: {
                checks += 1
                if checks == 2 {
                    try! FileManager.default.moveItem(at: destination, to: movedDestination)
                    try! FileManager.default.createSymbolicLink(at: destination, withDestinationURL: redirectedDestination)
                }
                return false
            }
        )) { error in
            XCTAssertEqual(error as? FactoryResetBackupPublicationError, .destinationUnavailable)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: redirectedDestination.path).isEmpty)
    }

    func testPublisherDoesNotCompleteAfterCancellationOrRetentionFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-reset-publisher-" + UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        let raw = root.appendingPathComponent("raw/7.plaudaudio")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try payload.write(to: raw)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = FactoryResetBackupSnapshot(serialNumber: "882-fixture", model: "notepins",
                                                  protocolVersion: 20, recorderInventory: inventory)
        XCTAssertThrowsError(try FactoryResetBackupPublisher.publish(
            snapshot: snapshot,
            rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
            selectedDestination: destination,
            expectationSink: ExpectationSink(fails: true)
        )) { error in
            XCTAssertEqual(error as? FactoryResetBackupPublicationError, .expectationNotRetained)
        }

        var checks = 0
        XCTAssertThrowsError(try FactoryResetBackupPublisher.publish(
            snapshot: snapshot,
            rawArtifacts: [FactoryResetBackupSourceArtifact(sessionID: 7, rawURL: raw)],
            selectedDestination: destination,
            expectationSink: ExpectationSink(),
            shouldCancel: {
                checks += 1
                return checks >= 4
            }
        )) { error in
            XCTAssertEqual(error as? FactoryResetBackupPublicationError, .cancelled)
        }
    }
}
