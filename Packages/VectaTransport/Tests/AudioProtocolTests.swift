import XCTest
@testable import NotePinAudio

final class AudioProtocolTests: XCTestCase {
    func testFullRequestStartsAtZeroAndEndsAtAdvertisedSize() {
        XCTAssertEqual(AudioDownloadPacket.fullRequest(session: 0x12345678, end: 0x00001000),
                       Data([1, 0x1c, 0, 0x78, 0x56, 0x34, 0x12] +
                            [0, 0, 0, 0, 0, 0x10, 0, 0]))
    }
    func testHeadTailAndByteOffsetFollowVendorLayout() throws {
        XCTAssertEqual(try AudioDownloadPacket.parse(Data([1, 0x1c, 0, 4, 3, 2, 1, 0])), .head(session: 0x01020304, status: 0))
        XCTAssertEqual(try AudioDownloadPacket.parse(Data([1, 0x1d, 0, 4, 3, 2, 1, 0x34, 0x12])), .tail(session: 0x01020304, crc: 0x1234))
        XCTAssertEqual(try AudioDownloadPacket.parse(Data([3, 4, 3, 2, 1, 0x20, 1, 0, 0, 3, 9, 8, 7])), .data(session: 0x01020304, offset: 288, bytes: Data([9, 8, 7])))
    }
    func testRejectsTruncatedExcessAndZeroLengthPackets() {
        for bytes: [UInt8] in [[], [1, 0x1c], [1, 0x1c, 0, 0, 0, 0, 0],
                                [1, 0x1d, 0, 0, 0, 0, 0, 0, 0, 0],
                                [3, 1, 0, 0, 0, 0, 0, 0, 0, 2, 8],
                                [3, 1, 0, 0, 0, 0, 0, 0, 0, 0]] {
            XCTAssertThrowsError(try AudioDownloadPacket.parse(Data(bytes)))
        }
    }
    func testEmptySentinelIsNeverAudio() throws {
        XCTAssertEqual(try AudioDownloadPacket.parse(Data([3, 1, 0, 0, 0, 255, 255, 255, 255, 0, 7])), .empty(session: 1, code: 7))
    }

    func testPaddedEndMarkerNeverAppendsPaddingOrPublishesWithoutTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = try AudioDownloadCollector(session: 1, expectedByteSize: 1, stagingURL: root.appendingPathComponent("raw"))
        let marker = Data([2, 1, 0, 0, 0, 255, 255, 255, 255, 160, 0]) + Data(repeating: 99, count: 159)
        let packet = try XCTUnwrap(AudioDownloadPacket.parseTransfer(marker))
        XCTAssertEqual(packet, .empty(session: 1, code: 0))
        try collector.accept(.head(session: 1, status: 0))
        XCTAssertThrowsError(try collector.accept(packet))
        try collector.accept(.data(session: 1, offset: 0, bytes: Data([7])))
        XCTAssertNil(try collector.accept(packet))
        let url = try XCTUnwrap(collector.accept(.tail(session: 1, crc: NativeAudioCRC.calculate(Data([7])))))
        XCTAssertEqual(try Data(contentsOf: url), Data([7]))
    }

    func testUnrelatedControlResponseDoesNotInterruptTransferButMalformedAudioFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([7, 8, 9])
        let collector = try AudioDownloadCollector(session: 1, expectedByteSize: 3,
                                                   stagingURL: root.appendingPathComponent("recording.raw"))
        try collector.accept(try XCTUnwrap(AudioDownloadPacket.parseTransfer(
            Data([1, 0x1c, 0, 1, 0, 0, 0, 0]))))
        // A valid recorder-state response arrives on the same encrypted TX.
        XCTAssertNil(try AudioDownloadPacket.parseTransfer(Data([1, 3, 0, 0, 0, 0, 0, 0])))
        XCTAssertEqual(collector.receivedByteCount, 0)
        XCTAssertThrowsError(try AudioDownloadPacket.parseTransfer(Data([1, 0x1c])))
        XCTAssertThrowsError(try AudioDownloadPacket.parseTransfer(Data([1, 0x1d, 0, 1])))
        XCTAssertThrowsError(try AudioDownloadPacket.parseTransfer(Data([3, 1, 0])))
        try collector.accept(try XCTUnwrap(AudioDownloadPacket.parseTransfer(
            Data([3, 1, 0, 0, 0, 0, 0, 0, 0, 3]) + bytes)))
        let crc = NativeAudioCRC.calculate(bytes)
        let result = try collector.accept(try XCTUnwrap(AudioDownloadPacket.parseTransfer(
            Data([1, 0x1d, 0, 1, 0, 0, 0, UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]))))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result)), bytes)
    }

    func testCollectorRequiresContiguousVerifiedFullFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([1, 2, 3, 4, 5])
        let collector = try AudioDownloadCollector(session: 9, expectedByteSize: 5,
                                                   stagingURL: root.appendingPathComponent("recording.raw"))
        XCTAssertNil(try collector.accept(.head(session: 9, status: 0)))
        XCTAssertThrowsError(try collector.accept(.data(session: 9, offset: 1, bytes: Data([1])))) { error in
            XCTAssertEqual(error as? NativeAudioError, .unexpectedOffset)
        }
        XCTAssertNil(try collector.accept(.data(session: 9, offset: 0, bytes: bytes)))
        XCTAssertThrowsError(try collector.accept(.tail(session: 9, crc: 0))) { error in
            XCTAssertEqual(error as? NativeAudioError, .checksumMismatch)
        }
        let crc = NativeAudioCRC.calculate(bytes)
        let verified = try collector.accept(.tail(session: 9, crc: crc))
        XCTAssertEqual(verified, root.appendingPathComponent("recording.raw"))
        XCTAssertEqual(try Data(contentsOf: verified!), bytes)
        try? FileManager.default.removeItem(at: root)
    }
    func testUnavailableCRCRequiresAuthenticatedPacketsAndExactSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strict = try AudioDownloadCollector(session: 1, expectedByteSize: 1, stagingURL: root.appendingPathComponent("strict"))
        try strict.accept(.head(session: 1, status: 0)); try strict.accept(.data(session: 1, offset: 0, bytes: Data([7])))
        XCTAssertThrowsError(try strict.accept(.tail(session: 1, crc: 0xffff)))
        let secure = try AudioDownloadCollector(session: 1, expectedByteSize: 1, stagingURL: root.appendingPathComponent("secure"), crcInitial: 0xffff, authenticatedPackets: true)
        try secure.accept(.head(session: 1, status: 0))
        XCTAssertThrowsError(try secure.accept(.tail(session: 1, crc: 0xffff)))
        try secure.accept(.data(session: 1, offset: 0, bytes: Data([7])))
        XCTAssertThrowsError(try secure.accept(.tail(session: 1, crc: 123)))
        XCTAssertNotNil(try secure.accept(.tail(session: 1, crc: 0xffff)))
        XCTAssertEqual(NativeAudioCRC.update(0xffff, Data("123456789".utf8)), 0x29b1)
    }

    func testCRCIndependentCheckValueAndChunking() {
        let first = Data("1234".utf8), second = Data("56789".utf8)
        XCTAssertEqual(NativeAudioCRC.calculate(first + second), 0x31c3)
        XCTAssertEqual(NativeAudioCRC.update(NativeAudioCRC.calculate(first), second), 0x31c3)
    }
    func testCollectorRejectsWrongSessionIncompleteTailAndExistingOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("recording.raw")
        let collector = try AudioDownloadCollector(session: 9, expectedByteSize: 5, stagingURL: path)
        XCTAssertThrowsError(try AudioDownloadCollector(session: 9, expectedByteSize: 5, stagingURL: path)) { error in
            XCTAssertEqual(error as? NativeAudioError, .outputExists)
        }
        XCTAssertThrowsError(try collector.accept(.head(session: 8, status: 0))) { error in
            XCTAssertEqual(error as? NativeAudioError, .sessionMismatch)
        }
        try collector.accept(.head(session: 9, status: 0))
        XCTAssertThrowsError(try collector.accept(.tail(session: 9, crc: 0))) { error in
            XCTAssertEqual(error as? NativeAudioError, .incompleteAudio)
        }
    }
    func testEncryptedHeaderOffsetsAndExactMinimumSize() throws {
        var h = Data(repeating: 0, count: 512)
        h.replaceSubrange(0..<8, with: Data("PLAUD.AI".utf8)); h[8] = 1; h[11] = 2
        h[48] = 3; h[50] = 2; h[52] = 1
        h.replaceSubrange(54..<58, with: audioLE(12340)); h[128] = 9
        h.replaceSubrange(132..<144, with: Data(0..<12)); h[256] = 0xab
        let parsed = try EncryptedAudioHeader(data: h)
        XCTAssertEqual(parsed.version, 1); XCTAssertEqual(parsed.fileType, 3)
        XCTAssertEqual(parsed.channels, 2); XCTAssertEqual(parsed.durationSeconds, 12340)
        XCTAssertEqual(parsed.counter, 9); XCTAssertEqual(parsed.nonce, Data(0..<12))
        XCTAssertEqual(parsed.encryptedKey.count, 256); XCTAssertEqual(parsed.encryptedKey.first, 0xab)
        XCTAssertThrowsError(try EncryptedAudioHeader(data: h.prefix(511)))
        h[10] = 1
        XCTAssertThrowsError(try EncryptedAudioHeader(data: h))
    }
    func testSegmentedFileEncryptionRestartsStreamForEveryFrame() throws {
        var h = Data(repeating: 0, count: 512)
        h.replaceSubrange(0..<8, with: Data("PLAUD.AI".utf8)); h[11] = 2; h[144] = 80
        let header = try EncryptedAudioHeader(data: h)
        let key = Data(0..<32), plain = Data(repeating: 7, count: 170)
        let ciphertext = try header.decryptPayload(plain, key: key)
        XCTAssertEqual(ciphertext.prefix(80), ciphertext.dropFirst(80).prefix(80))
        XCTAssertEqual(try header.decryptPayload(ciphertext, key: key), plain)
        XCTAssertNotEqual(try AudioChaCha20.apply(ciphertext, key: key, nonce: header.nonce), plain)
    }

    func testRFC8439ChaCha20KnownAnswerAcrossBlockBoundary() throws {
        let key = Data(0..<32), nonce = hex("000000000000004a00000000")
        let plain = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let expected = hex("6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b" +
                           "f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8" +
                           "07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736" +
                           "5af90bbf74a35be6b40b8eedf2785e42874d")
        XCTAssertEqual(try AudioChaCha20.apply(plain, key: key, nonce: nonce, initialCounter: 1), expected)
        XCTAssertEqual(try AudioChaCha20.apply(Data(), key: key, nonce: nonce), Data())
        XCTAssertThrowsError(try AudioChaCha20.apply(plain, key: Data(), nonce: nonce))
        XCTAssertThrowsError(try AudioChaCha20.apply(Data(repeating: 0, count: 65), key: key, nonce: nonce, initialCounter: UInt32.max))
    }
    private func hex(_ text: String) -> Data {
        let b = Array(text)
        return Data(stride(from: 0, to: b.count, by: 2).map { UInt8(String(b[$0...($0 + 1)]), radix: 16)! })
    }
}
