import Foundation
import CryptoKit

enum VectaRecordingStatus: String, Codable {
    case copying
    case local
    case uploading
    case transcribing
    case ready
    case failed
    case needsSupport
}

struct VectaCloudCompletedPart: Codable, Equatable {
    let partNumber: Int
    let etag: String
}

struct VectaCloudUploadPart: Codable, Equatable {
    let partNumber: Int
    let presignedURL: String

    private enum CodingKeys: String, CodingKey {
        case partNumber
        case presignedURL = "presignedUrl"
    }
}

struct VectaCloudCheckpoint: Codable, Equatable {
    var createRequestID: String?
    let uploadJobID: String
    var chunkSize: Int?
    var uploadParts: [VectaCloudUploadPart]?
    var completedParts: [VectaCloudCompletedPart]
    var transcriptionID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case createRequestID = "createRequestId"
        case uploadJobID = "uploadJobId"
        case chunkSize, uploadParts, completedParts
        case transcriptionID = "transcriptionId"
    }

    var canResumeWithoutLocalAudio: Bool {
        if let transcriptionID, !transcriptionID.isEmpty { return true }
        let completedNumbers = Set(completedParts.map(\.partNumber))
        if let uploadParts, !uploadParts.isEmpty {
            return Set(uploadParts.map(\.partNumber)).isSubset(of: completedNumbers)
        }
        return !completedParts.isEmpty
    }
}

enum VectaRecorderReleasePhase: String, Codable {
    case requested
    case cloudConfirmed
    case localDepaired
}

/// Archived release metadata; Vecta does not send backend bind/unbind commands.
struct VectaRecorderReleaseCheckpoint: Codable, Equatable {
    let serialNumber: String
    let deviceType: String
    var phase: VectaRecorderReleasePhase
    var updatedAt: Date
}

enum VectaRecorderAssociationPhase: String, Codable {
    case bindRequested
    case bound
}

struct VectaRecorderAssociation: Codable, Equatable {
    let serialNumber: String
    let deviceType: String
    var phase: VectaRecorderAssociationPhase
    var updatedAt: Date
}

enum VectaRecorderAssociationBeginResult: Equatable {
    case ready(VectaRecorderAssociation)
    case identityConflict(VectaRecorderAssociation)
    case persistenceFailed
}

struct VectaRecording: Codable, Equatable {
    let sessionID: Int
    let deviceSerialNumber: String
    let createdAt: Date
    var duration: TimeInterval
    var localFileName: String?
    var status: VectaRecordingStatus
    var statusDetail: String?
    var transcript: String?
    /// Durable Partner transcription identity. Summary generation, retries,
    /// and future intelligence actions must not depend on a cleared upload
    /// checkpoint once the transcript is ready.
    var transcriptionID: String?
    var cloudCheckpoint: VectaCloudCheckpoint?
    var updatedAt: Date
    var generatedTitle: String? = nil
    var importedTitle: String? = nil

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case deviceSerialNumber, createdAt, duration, localFileName, status, statusDetail, transcript
        case transcriptionID = "transcriptionId"
        case cloudCheckpoint, updatedAt, generatedTitle, importedTitle
    }

    var title: String {
        if let generatedTitle { return generatedTitle }
        if let importedTitle { return importedTitle }
        let formatter = DateFormatter()
        formatter.locale=VL.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return VL.text("Запись · ") + formatter.string(from: createdAt)
    }
}

