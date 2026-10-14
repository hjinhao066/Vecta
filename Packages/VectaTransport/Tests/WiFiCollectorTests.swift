import Foundation
import XCTest
@testable import NotePinTransport

/// Synthetic protocol and full-file consistency checks, not real device acceptance.
final class WiFiCollectorTests: XCTestCase {
    private let first = WiFiRecordingFile(session: 0x12345678, size: 100, scene: 0xabcd)
    private let second = WiFiRecordingFile(session: 0x9abcdef0, size: 200, scene: 0x0201)

    private func page(_ files: [WiFiRecordingFile], count: UInt32, offset: UInt32 = 0,
                      status: Int32 = 0, uid: UInt32? = nil) throws -> WiFiEnvelope {
        var tail = Data()
        for file in files {
            for value in [file.session, file.size] {
                tail.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) })
            }
            tail.append(contentsOf: [UInt8(file.scene & 255), UInt8(file.scene >> 8)])
        }
        return try WiFiEnvelope(metadata: WiFiListResponse(status: status, count: count, offset: offset, uid: uid), binary: tail)
    }

    private func content(session: UInt32 = 9, offset: UInt32, bytes: [UInt8], last: UInt8,
                         length: UInt32? = nil) throws -> WiFiEnvelope {
        try WiFiEnvelope(metadata: WiFiContentMetadata(session: session, offset: offset,
                                                       length: length ?? UInt32(bytes.count), last: last),
                         binary: Data(bytes))
    }

    func testListRecordUsesU16SceneNotBLETail() throws {
        let envelope = try page([first], count: 1)
        XCTAssertEqual(envelope.binary, Data([0x78, 0x56, 0x34, 0x12, 100, 0, 0, 0, 0xcd, 0xab]))
        let decoded = try WiFiFileListPage(envelope: WiFiEnvelope.decode(envelope.encoded()))
        XCTAssertEqual(decoded.files, [first])
        XCTAssertEqual(decoded.files[0].scene, 0xabcd)
        XCTAssertEqual(decoded.metadata.count, 1)
    }

    func testListSequentialCompleteAndEmptyInventory() throws {
        var collector = try WiFiFileListCollector()
        XCTAssertNil(try collector.accept(page([first], count: 2)))
        XCTAssertEqual(collector.receivedCount, 1)
        XCTAssertNil(collector.completedFiles)
        XCTAssertEqual(try collector.accept(page([second], count: 2, offset: 1)), [first, second])
        XCTAssertTrue(collector.isComplete)
        XCTAssertThrowsError(try collector.accept(page([second], count: 2, offset: 1)))
        var empty = try WiFiFileListCollector(maximumFiles: 0, expectedFiles: [])
        XCTAssertEqual(try empty.accept(page([], count: 0)), [])
        XCTAssertTrue(empty.isComplete)
    }

    func testListTruncationExcessAndRangeValidation() throws {
        let original = try page([first], count: 1)
        for count in 1..<10 {
            let partial = try WiFiEnvelope(command: .list, json: original.json, binary: Data(original.binary.prefix(count)))
            XCTAssertThrowsError(try WiFiFileListPage(envelope: partial))
        }
        XCTAssertThrowsError(try WiFiFileListPage(envelope: page([first, second], count: 1)))
        XCTAssertThrowsError(try WiFiFileListPage(envelope: page([first], count: 1, offset: 1)))
        XCTAssertThrowsError(try WiFiFileListPage(envelope: page([], count: 1, offset: 2)))
        XCTAssertThrowsError(try WiFiFileListPage(envelope: page([], count: UInt32.max)))
        XCTAssertThrowsError(try WiFiFileListPage(envelope: page([], count: 0), maximumFiles: -1))
        var bounded = try WiFiFileListCollector(maximumFiles: 1)
        XCTAssertThrowsError(try bounded.accept(WiFiFileListPage(envelope: page([first], count: 2))))
        XCTAssertEqual(bounded.receivedCount, 0)
    }

    func testListRejectsRemoteFailureWrongTypeAndMalformedMetadata() throws {
        XCTAssertThrowsError(try WiFiFileListPage(envelope: page([], count: 0, status: -1))) {
            XCTAssertEqual($0 as? WiFiProtocolError, .remoteStatus(-1))
        }
        XCTAssertThrowsError(try WiFiFileListPage(envelope: WiFiEnvelope(metadata: WiFiHeartbeat())))
        for json in ["{\"count\":0,\"offset\":0}", "{\"status\":0,\"count\":-1,\"offset\":0}",
                     "{\"status\":0,\"count\":1,\"offset\":-1}", "{\"status\":0,\"count\":1}"] {
            XCTAssertThrowsError(try WiFiFileListPage(envelope: WiFiEnvelope(command: .list, json: Data(json.utf8))))
        }
    }

    func testListRejectsGapsDuplicatesChangedCountsAndEmptyProgressAtomically() throws {
        var collector = try WiFiFileListCollector()
        XCTAssertThrowsError(try collector.accept(page([second], count: 2, offset: 1)))
        XCTAssertNil(try collector.accept(page([first], count: 2)))
        XCTAssertThrowsError(try collector.accept(page([first], count: 2)))
        XCTAssertThrowsError(try collector.accept(page([second], count: 3, offset: 1)))
        XCTAssertThrowsError(try collector.accept(page([], count: 2, offset: 1)))
        XCTAssertThrowsError(try collector.accept(page([first], count: 2, offset: 1)))
        XCTAssertEqual(collector.receivedCount, 1)
        XCTAssertEqual(try collector.accept(page([second], count: 2, offset: 1)), [first, second])
        var duplicate = try WiFiFileListCollector()
        XCTAssertThrowsError(try duplicate.accept(page([first, first], count: 2)))
        XCTAssertEqual(duplicate.receivedCount, 0)
    }

    func testListBaselineRejectsChangedInventoryAllowsOrderingAndDistinctScenes() throws {
        var collector = try WiFiFileListCollector(expectedFiles: [first, second])
        let resized = WiFiRecordingFile(session: first.session, size: first.size + 1, scene: first.scene)
        let rescened = WiFiRecordingFile(session: first.session, size: first.size, scene: first.scene + 1)
        let replaced = WiFiRecordingFile(session: 7, size: first.size, scene: first.scene)
        for file in [resized, rescened, replaced] {
            XCTAssertThrowsError(try collector.accept(page([file], count: 2)))
        }
        XCTAssertThrowsError(try collector.accept(page([first], count: 1)))
        XCTAssertEqual(collector.receivedCount, 0)
        XCTAssertEqual(try collector.accept(page([second, first], count: 2)), [second, first])
        XCTAssertThrowsError(try WiFiFileListCollector(expectedFiles: [first, first]))
        XCTAssertThrowsError(try WiFiFileListCollector(maximumFiles: 1, expectedFiles: [first, second]))
        XCTAssertThrowsError(try WiFiFileListCollector(maximumFiles: -1))
        let alternateScene = WiFiRecordingFile(session: first.session, size: 99, scene: 2)
        var scenes = try WiFiFileListCollector(expectedFiles: [first, alternateScene])
        XCTAssertEqual(try scenes.accept(page([first, alternateScene], count: 2)), [first, alternateScene])
    }

    func testLiveListPagesRequireMatchingRequestIdentifierAndRejectStalePagesAtomically() throws {
        var collector = try WiFiFileListCollector(expectedUID: 7)
        for uid: UInt32? in [nil, 0, 6, 8] {
            XCTAssertThrowsError(try collector.accept(page([first], count: 2, uid: uid))) {
                XCTAssertEqual($0 as? WiFiProtocolError, .unexpectedRequestID)
            }
            XCTAssertEqual(collector.receivedCount, 0)
        }
        XCTAssertNil(try collector.accept(page([first], count: 2, uid: 7)))
        XCTAssertThrowsError(try collector.accept(page([second], count: 2, offset: 1, uid: 6)))
        XCTAssertEqual(collector.receivedCount, 1)
        XCTAssertThrowsError(try collector.accept(page([second], count: 3, offset: 1, uid: 7)))
        XCTAssertThrowsError(try collector.accept(page([second], count: 2, offset: 0, uid: 7)))
        XCTAssertEqual(try collector.accept(page([second], count: 2, offset: 1, uid: 7)), [first, second])
    }

    func testFullFileCollectorExposesOnlyVerifiedCompletion() throws {
        var collector = try WiFiFileCollector(expectedSession: 9, expectedSize: 5)
        try collector.begin(WiFiEnvelope(metadata: WiFiDownloadResponse(status: 0, session: 9, total: 5)))
        XCTAssertNil(try collector.accept(content(offset: 0, bytes: [0x4f, 0x67], last: 0)))
        XCTAssertNil(collector.completedFile)
        XCTAssertEqual(collector.state.receivedByteCount, 2)
        XCTAssertThrowsError(try collector.finish())
        XCTAssertEqual(try collector.accept(content(offset: 2, bytes: [0x67, 0x53, 0xff], last: 1)),
                       Data([0x4f, 0x67, 0x67, 0x53, 0xff]))
        XCTAssertTrue(collector.state.isComplete)
        try collector.finish()
        XCTAssertThrowsError(try collector.accept(content(offset: 5, bytes: [], last: 1)))
        XCTAssertEqual(collector.completedFile, Data([0x4f, 0x67, 0x67, 0x53, 0xff]))
    }

    func testFileRequiresAcceptedMatchingTotalResponseBeforeContent() throws {
        var state = WiFiFileTransferState(expectedSession: 9, expectedSize: 3)
        XCTAssertThrowsError(try state.accept(content(offset: 0, bytes: [1, 2, 3], last: 1))) {
            XCTAssertEqual($0 as? WiFiProtocolError, .transferNotStarted)
        }
        XCTAssertThrowsError(try state.begin(WiFiDownloadResponse(status: 4, session: 9, total: 3)))
        XCTAssertThrowsError(try state.begin(WiFiDownloadResponse(status: 0, session: 9, total: 2)))
        XCTAssertThrowsError(try state.begin(WiFiDownloadResponse(status: 0, session: 9, total: 4)))
        XCTAssertFalse(state.isStarted)
        try state.begin(WiFiDownloadResponse(status: 0, session: 9, total: 3))
        XCTAssertThrowsError(try state.begin(WiFiDownloadResponse(status: 0, session: 9, total: 3)))
        XCTAssertTrue(try state.accept(content(offset: 0, bytes: [1, 2, 3], last: 1)))
        try state.finish()
    }

    func testOptionalTotalAcknowledgmentsStillRequireSessionAndCompleteInventorySize() throws {
        for total: UInt32? in [nil, 0, 3] {
            var state = WiFiFileTransferState(expectedSession: 9, expectedSize: 3)
            XCTAssertThrowsError(try state.begin(WiFiDownloadResponse(status: 0, session: 10, total: total))) {
                XCTAssertEqual($0 as? WiFiProtocolError, .wrongSession)
            }
            XCTAssertThrowsError(try state.begin(WiFiDownloadResponse(status: 1, session: 9, total: total)))
            XCTAssertFalse(state.isStarted)
            try state.begin(WiFiDownloadResponse(status: 0, session: 9, total: total))
            XCTAssertThrowsError(try state.accept(content(offset: 0, bytes: [1, 2], last: 1)))
            XCTAssertThrowsError(try state.accept(content(offset: 0, bytes: [1, 2, 3, 4], last: 1)))
            XCTAssertEqual(state.receivedByteCount, 0)
            XCTAssertTrue(try state.accept(content(offset: 0, bytes: [1, 2, 3], last: 1)))
            try state.finish()
        }
    }

    func testFileRejectsWrongSessionGapsDuplicatesAndBLESplice() throws {
        var collector = try WiFiFileCollector(expectedSession: 9, expectedSize: 4)
        try collector.begin(WiFiDownloadResponse(status: 0, session: 9, total: 4))
        // A partial BLE buffer cannot be adopted: the first WiFi offset must be zero.
        XCTAssertThrowsError(try collector.accept(content(offset: 2, bytes: [3, 4], last: 1)))
        XCTAssertThrowsError(try collector.accept(content(session: 10, offset: 0, bytes: [1], last: 0)))
        XCTAssertNil(try collector.accept(content(offset: 0, bytes: [1, 2], last: 0)))
        XCTAssertThrowsError(try collector.accept(content(offset: 0, bytes: [1, 2], last: 0)))
        XCTAssertThrowsError(try collector.accept(content(offset: 3, bytes: [4], last: 1)))
        XCTAssertThrowsError(try collector.accept(content(offset: 1, bytes: [2, 3, 4], last: 1)))
        XCTAssertEqual(collector.state.receivedByteCount, 2)
        XCTAssertEqual(try collector.accept(content(offset: 2, bytes: [3, 4], last: 1)), Data([1, 2, 3, 4]))
    }

    func testFileRejectsDeclaredLengthAndTailMismatchExcessAndEarlyTerminal() throws {
        var state = WiFiFileTransferState(expectedSession: 9, expectedSize: 4)
        try state.begin(WiFiDownloadResponse(status: 0, session: 9, total: 4))
        for envelope in [try content(offset: 0, bytes: [1, 2], last: 0, length: 1),
                         try content(offset: 0, bytes: [1], last: 0, length: 2),
                         try content(offset: 0, bytes: [1, 2, 3, 4, 5], last: 1),
                         try content(offset: 0, bytes: [1, 2], last: 1),
                         try content(offset: 0, bytes: [], last: 1),
                         try content(offset: 0, bytes: [], last: 0)] {
            XCTAssertThrowsError(try state.accept(envelope))
            XCTAssertEqual(state.receivedByteCount, 0)
            XCTAssertFalse(state.isComplete)
        }
        let invalidLast = WiFiContentMetadata(session: 9, offset: 0, length: 4, last: 2)
        XCTAssertThrowsError(try state.accept(invalidLast, binary: Data([1, 2, 3, 4])))
        XCTAssertTrue(try state.accept(content(offset: 0, bytes: [1, 2, 3, 4], last: 1)))
    }

    func testTotalAloneIsNotTerminalAndZeroByteTerminalIsSupported() throws {
        var collector = try WiFiFileCollector(expectedSession: 9, expectedSize: 2)
        try collector.begin(WiFiDownloadResponse(status: 0, session: 9, total: 2))
        XCTAssertNil(try collector.accept(content(offset: 0, bytes: [1, 2], last: 0)))
        XCTAssertFalse(collector.state.isComplete)
        XCTAssertThrowsError(try collector.finish())
        XCTAssertThrowsError(try collector.accept(content(offset: 2, bytes: [3], last: 1)))
        XCTAssertEqual(try collector.accept(content(offset: 2, bytes: [], last: 1)), Data([1, 2]))
        try collector.finish()
        var empty = try WiFiFileCollector(expectedSession: 9, expectedSize: 0, maximumFileSize: 0)
        try empty.begin(WiFiDownloadResponse(status: 0, session: 9, total: 0))
        XCTAssertNil(empty.completedFile)
        XCTAssertEqual(try empty.accept(content(offset: 0, bytes: [], last: 1)), Data())
        try empty.finish()
    }

    func testPureStateSupportsUInt32SizeWithoutAllocationAndPreventsOverflow() throws {
        var state = WiFiFileTransferState(expectedSession: UInt32.max, expectedSize: UInt32.max)
        try state.begin(WiFiDownloadResponse(status: 0, session: UInt32.max, total: UInt32.max))
        XCTAssertFalse(try state.accept(WiFiContentMetadata(session: UInt32.max, offset: 0, length: 1, last: 0),
                                        binary: Data([1])))
        XCTAssertEqual(state.receivedByteCount, 1)
        XCTAssertThrowsError(try state.accept(WiFiContentMetadata(session: UInt32.max, offset: 1, length: UInt32.max, last: 0),
                                              binary: Data([1])))
        XCTAssertThrowsError(try state.accept(WiFiContentMetadata(session: UInt32.max, offset: UInt32.max, length: 1, last: 0),
                                              binary: Data([1])))
        XCTAssertEqual(state.receivedByteCount, 1)
        XCTAssertThrowsError(try state.finish())
    }

    func testMemoryCollectorHasExplicitCheckedBounds() throws {
        XCTAssertThrowsError(try WiFiFileCollector(expectedSession: 1, expectedSize: 1, maximumFileSize: -1))
        XCTAssertThrowsError(try WiFiFileCollector(expectedSession: 1, expectedSize: 2, maximumFileSize: 1))
        XCTAssertThrowsError(try WiFiFileCollector(expectedSession: 1, expectedSize: UInt32.max))
        let bounded = try WiFiFileCollector(expectedSession: 1, expectedSize: 2, maximumFileSize: 2)
        XCTAssertEqual(bounded.state.receivedByteCount, 0)
        // The override is checked and does not reserve expectedSize bytes.
        let explicit = try WiFiFileCollector(expectedSession: 1, expectedSize: UInt32.max, maximumFileSize: Int(UInt32.max))
        XCTAssertNil(explicit.completedFile)
    }

    func testFileWrongCommandAndExtraResponseTailRejectWithoutStateMutation() throws {
        var state = WiFiFileTransferState(expectedSession: 9, expectedSize: 1)
        XCTAssertThrowsError(try state.begin(WiFiEnvelope(metadata: WiFiHeartbeat())))
        let response = try WiFiEnvelope(metadata: WiFiDownloadResponse(status: 0, session: 9, total: 1))
        let extra = try WiFiEnvelope(command: .download, json: response.json, binary: Data([0]))
        XCTAssertThrowsError(try state.begin(extra))
        XCTAssertFalse(state.isStarted)
        try state.begin(response)
        XCTAssertThrowsError(try state.accept(WiFiEnvelope(metadata: WiFiHeartbeat())))
        XCTAssertEqual(state.receivedByteCount, 0)
        XCTAssertTrue(try state.accept(content(offset: 0, bytes: [1], last: 1)))
    }
}
