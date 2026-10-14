import Foundation

public enum FactoryResetBackupCoordinatorError: Error, Equatable {
    case invalidSnapshot
    case inventoryUnavailable
    case transferFailed
    case inventoryChanged
    case cancelled
}

/// Coordinates a backup-only transaction over caller-supplied authenticated
/// inventory and raw-transfer adapters. It has no reset capability.
public enum FactoryResetBackupCoordinator {
    public static func publish(
        freshSnapshot: () throws -> FactoryResetBackupSnapshot,
        downloadRaw: (FactoryResetBackupSnapshot, ProtocolRecordingFile) throws -> URL,
        revalidateSnapshot: () throws -> FactoryResetBackupSnapshot,
        selectedDestination: URL,
        expectationSink: FactoryResetBackupExpectationSink,
        shouldCancel: () -> Bool = { false }
    ) throws -> FactoryResetBackupPublication {
        try checkCancelled(shouldCancel)
        let snapshot: FactoryResetBackupSnapshot
        do {
            snapshot = try freshSnapshot()
        } catch {
            throw FactoryResetBackupCoordinatorError.inventoryUnavailable
        }
        try validate(snapshot)

        var rawArtifacts: [FactoryResetBackupSourceArtifact] = []
        for recording in snapshot.recorderInventory where recording.byteSize > 0 {
            try checkCancelled(shouldCancel)
            let rawURL: URL
            do {
                rawURL = try downloadRaw(snapshot, recording)
            } catch {
                throw FactoryResetBackupCoordinatorError.transferFailed
            }
            rawArtifacts.append(FactoryResetBackupSourceArtifact(sessionID: recording.sessionID, rawURL: rawURL))
        }

        try checkCancelled(shouldCancel)
        let revalidated: FactoryResetBackupSnapshot
        do {
            revalidated = try revalidateSnapshot()
        } catch {
            throw FactoryResetBackupCoordinatorError.inventoryUnavailable
        }
        guard revalidated == snapshot else {
            throw FactoryResetBackupCoordinatorError.inventoryChanged
        }
        try checkCancelled(shouldCancel)
        return try FactoryResetBackupPublisher.publish(snapshot: snapshot,
                                                       rawArtifacts: rawArtifacts,
                                                       selectedDestination: selectedDestination,
                                                       expectationSink: expectationSink,
                                                       shouldCancel: shouldCancel)
    }

    private static func validate(_ snapshot: FactoryResetBackupSnapshot) throws {
        guard !snapshot.serialNumber.isEmpty,
              !snapshot.model.isEmpty,
              snapshot.protocolVersion > 0 else {
            throw FactoryResetBackupCoordinatorError.invalidSnapshot
        }
        var sessionIDs = Set<UInt32>()
        for recording in snapshot.recorderInventory {
            guard recording.sessionID > 0, sessionIDs.insert(recording.sessionID).inserted else {
                throw FactoryResetBackupCoordinatorError.invalidSnapshot
            }
        }
    }

    private static func checkCancelled(_ shouldCancel: () -> Bool) throws {
        guard !shouldCancel() else { throw FactoryResetBackupCoordinatorError.cancelled }
    }
}
