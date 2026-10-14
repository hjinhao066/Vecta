import CryptoKit
import XCTest
@testable import NotePinTransport

final class ProtocolWireTests: XCTestCase {
    func testExplicitNotePinSRecoveryKeepsSignatureAndChangesOnlyMarker() throws {
        let signature = Data((0..<256).map { UInt8(truncatingIfNeeded: $0) })
        let normal = try ProtocolBootstrap.signaturePackets(signature)
        let recovery = try ProtocolBootstrap.recoverySignaturePackets(signature, model: .notePinS, protocolVersion: 20)
        XCTAssertEqual(recovery.map(\.count), [104, 104, 60])
        for (index, packet) in recovery.enumerated() {
            XCTAssertEqual(Array(packet.prefix(4)), [0x20, 0xfe, 3, UInt8(index)])
            XCTAssertEqual(packet.dropFirst(2), normal[index].dropFirst(2))
        }
        XCTAssertEqual(recovery.reduce(into: Data()) { $0.append($1.dropFirst(4)) }, signature)
    }

    func testRecoveryRejectsOtherModelsLegacyVersionsAndInvalidSignature() {
        for model in [PlaudModel.note, .notePin, .notePro] {
            XCTAssertThrowsError(try ProtocolBootstrap.recoverySignaturePackets(Data([1]), model: model, protocolVersion: 20))
        }
        for version: UInt16 in [0, 10, 19, 256] {
            XCTAssertThrowsError(try ProtocolBootstrap.recoverySignaturePackets(Data([1]), model: .notePinS, protocolVersion: version))
        }
        XCTAssertThrowsError(try ProtocolBootstrap.recoverySignaturePackets(Data(), model: .notePinS, protocolVersion: 20))
    }

    func testSignaturePacketsChunkDecodedBytesAndNeverForceClear() throws {
        let original = Data((0..<256).map { UInt8(truncatingIfNeeded: $0) })
        let packets = try ProtocolBootstrap.signaturePackets(original)
        XCTAssertEqual(packets.map(\.count), [104, 104, 60])
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(Array(packet.prefix(4)), [0x10, 0xfe, 3, UInt8(index)])
        }
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1.dropFirst(4)) }, original)
        XCTAssertThrowsError(try ProtocolBootstrap.signaturePackets(Data()))
        XCTAssertThrowsError(try ProtocolBootstrap.signaturePackets(Data(repeating: 1, count: 4097)))
    }

    func testPublicKeySendsPEMNotDER() throws {
        let pem = "-----BEGIN PUBLIC KEY-----\n" + String(repeating: "A", count: 240) + "\n-----END PUBLIC KEY-----"
        let packets = try ProtocolBootstrap.publicKeyPackets(pem)
        XCTAssertEqual(Array(packets[0].prefix(4)), [0x12, 0xfe, 3, 0])
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1.dropFirst(4)) }, Data(pem.utf8))
        XCTAssertThrowsError(try ProtocolBootstrap.publicKeyPackets("untrusted"))
    }

    func testAppleOwnerProfileKeepsTokenAndUsesNULPadding() throws {
        let token = "known-existing-owner"
        let first = try ProtocolBootstrap.ownerHandshake(token: token, checked: false)
        let second = try ProtocolBootstrap.ownerHandshake(token: token, checked: true)
        XCTAssertEqual(first.count, 38)
        XCTAssertEqual(Array(first.prefix(6)), [1, 1, 0, 1, 1, 0])
        XCTAssertEqual(Array(second.prefix(6)), [1, 1, 0, 1, 1, 1])
        XCTAssertEqual(first.dropFirst(6).prefix(token.utf8.count), Data(token.utf8))
        XCTAssertEqual(first.suffix(32 - token.utf8.count), Data(repeating: 0, count: 32 - token.utf8.count))
        let long = "12345678901234567890123456789012extra"
        XCTAssertEqual(try ProtocolBootstrap.ownerHandshake(token: long, checked: false).suffix(32), Data(long.utf8.prefix(32)))
        for bad in ["", "unsafe\nowner", "кириллица"] {
            XCTAssertThrowsError(try ProtocolBootstrap.ownerHandshake(token: bad, checked: false))
        }
    }

    func testStateAndListRequestsUseKnownReadonlyTypesAndLECorrelation() {
        XCTAssertEqual(ProtocolBootstrap.getState(), Data([1, 3, 0]))
        XCTAssertEqual(ProtocolBootstrap.getFileList(requestID: 0x12345678, startSessionID: 0x9abcdef0, onlyOne: true),
            Data([1, 0x1a, 0, 0x78, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a, 1]))
    }

    func testConfirmationAppendsDeveloperTokenAndUTF8NameExactly() throws {
        let absent = try ProtocolBootstrap.ownerConfirmation(token: "existing")
        XCTAssertEqual(absent.count, 47)
        XCTAssertEqual(absent.suffix(9), Data(repeating: 0, count: 9))
        let present = try ProtocolBootstrap.ownerConfirmation(token: "existing", developerToken: "partner-token", username: "Тест")
        XCTAssertEqual(Array(present[38..<46]), Array("partner-".utf8))
        XCTAssertEqual(present[46], UInt8("Тест".utf8.count))
        XCTAssertEqual(present.dropFirst(47), Data("Тест".utf8))
        XCTAssertThrowsError(try ProtocolBootstrap.ownerConfirmation(token: "existing", username: String(repeating: "a", count: 256)))
    }

    func testEmptyListCompletesWithoutInventedEntries() throws {
        let page = try ProtocolFileListPage.decode(Data([1, 0x1a, 0, 99, 0, 0, 0, 0, 0]), protocolVersion: 20)
        var collector = ProtocolFileListCollector(requestID: 99)
        XCTAssertEqual(try collector.accept(page), [])
    }

    func testOwnerResponseRecognizesOnlyStatusZeroAsSuccess() throws {
        let payload = Data([1, 1, 0, 0, 20, 0, 3, 30, 1, 1, 0, 1])
        guard case .status(let status) = try ProtocolOwnerResponse.decode(payload) else { return XCTFail("wrong type") }
        XCTAssertTrue(status.accepted)
        XCTAssertEqual(status.protocolVersion, 20)
        XCTAssertEqual(status.audioChannels, 1)
        XCTAssertEqual(status.supportsWiFi, true)
        XCTAssertEqual(status.isOggAudio, true)
        var denied = payload
        denied[3] = 4
        guard case .status(let failure) = try ProtocolOwnerResponse.decode(denied) else { return XCTFail("wrong type") }
        XCTAssertFalse(failure.accepted)
        XCTAssertEqual(failure.status, 4)
        XCTAssertThrowsError(try ProtocolOwnerResponse.decode(Data([1, 1, 0, 0])))
    }

    func testOwnerSerialDoesNotPretendAuthenticationCompleted() throws {
        let serial = "882SYNTHETICFIXTURE"
        var payload = Data([1, 2, 0])
        payload.append(Data(serial.utf8))
        payload.append(Data(repeating: 0, count: 56 - serial.utf8.count))
        XCTAssertEqual(try ProtocolOwnerResponse.decode(payload), .serialNumber(serial))
        payload[3] = 0
        XCTAssertThrowsError(try ProtocolOwnerResponse.decode(payload))
        XCTAssertThrowsError(try ProtocolOwnerResponse.decode(Data([1, 2, 0])))
    }

    func testRecorderStateReadsOptionalFieldsOnlyWhenPresent() throws {
        let short = try ProtocolRecorderState.decode(Data([1, 3, 0, 4, 3, 2, 1, 1]))
        XCTAssertEqual(short.state, 0x01020304)
        XCTAssertTrue(short.privacyEnabled)
        XCTAssertNil(short.sessionID)
        let full = try ProtocolRecorderState.decode(Data([1, 3, 0, 4, 3, 2, 1, 0, 1, 1, 2, 8, 7, 6, 5, 3, 4, 5]))
        XCTAssertEqual(full.sessionID, 0x05060708)
        XCTAssertEqual(full.scene, 2)
        XCTAssertEqual(full.findMyState, 3)
        XCTAssertEqual(full.httpTokenState, 5)
        XCTAssertThrowsError(try ProtocolRecorderState.decode(Data([1, 1, 0, 4, 3, 2, 1, 0])))
    }

    func testFileListUsesBytesNotInferredDurationAndCorrelatesPages() throws {
        let a = try ProtocolFileListPage.decode(page(total: 2, start: 0, session: 100, size: 12480), protocolVersion: 20)
        let b = try ProtocolFileListPage.decode(page(total: 2, start: 1, session: 200, size: 32000), protocolVersion: 20)
        XCTAssertEqual(a.files[0].byteSize, 12480)
        XCTAssertEqual(a.files[0].scene, 2)
        XCTAssertEqual(a.files[0].attribute, 3)
        var collector = ProtocolFileListCollector(requestID: 99)
        XCTAssertNil(try collector.accept(b))
        XCTAssertNil(try collector.accept(b)) // duplicate no double-count
        let files = try XCTUnwrap(collector.accept(a))
        XCTAssertEqual(files.map(\.sessionID), [100, 200])
        XCTAssertThrowsError(try collector.accept(ProtocolFileListPage.decode(page(request: 98, total: 2, start: 0, session: 100, size: 12480), protocolVersion: 20)))
        XCTAssertThrowsError(try collector.accept(ProtocolFileListPage.decode(page(total: 2, start: 0, session: 100, size: 13000), protocolVersion: 20)))
    }

    func testFileListRejectsPartialOrImpossiblePages() throws {
        var valid = page(total: 1, start: 0, session: 100, size: 12480)
        valid.removeLast()
        XCTAssertThrowsError(try ProtocolFileListPage.decode(valid, protocolVersion: 20))
        XCTAssertThrowsError(try ProtocolFileListPage.decode(page(total: 1, start: 1, session: 100, size: 12480), protocolVersion: 20))
        var bounded = ProtocolFileListCollector(requestID: 99, maximumFiles: 1)
        XCTAssertThrowsError(try bounded.accept(ProtocolFileListPage.decode(page(total: 2, start: 0, session: 100, size: 12480), protocolVersion: 20)))
        var collector = ProtocolFileListCollector(requestID: 99)
        XCTAssertNil(try collector.accept(ProtocolFileListPage.decode(page(total: 2, start: 0, session: 100, size: 12480), protocolVersion: 20)))
        XCTAssertThrowsError(try collector.accept(ProtocolFileListPage.decode(page(total: 3, start: 1, session: 100, size: 12480), protocolVersion: 20)))
    }

    func testEncryptedCommandInteroperatesWithIndependentCryptoKitOpen() throws {
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((32..<44).map(UInt8.init))
        let aad = Data((44..<56).map(UInt8.init))
        let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        let session = try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + proof.ciphertext + proof.tag)
        let payload = ProtocolBootstrap.getState()
        let encrypted = try session.sealPacket(sequence: 0x12345678, payload: payload)
        XCTAssertEqual(encrypted.count, 4 + payload.count + 16)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
            ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        XCTAssertEqual(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad),
            Data([0x78, 0x56, 0x34, 0x12, 1, 3, 0]))
        XCTAssertEqual(try session.decodePacket(encrypted), ReceivedPacket(sequence: 0x12345678, payload: payload))
        var tampered = encrypted
        tampered[0] ^= 1
        XCTAssertThrowsError(try session.decodePacket(tampered))
        tampered = encrypted
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try session.decodePacket(tampered))
        XCTAssertThrowsError(try session.sealPacket(sequence: 1, payload: Data()))
    }

    private func le(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    func testAudioFileAuthenticationPreservesEveryPlaintextByte() throws {
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((32..<44).map(UInt8.init))
        let aad = Data((44..<56).map(UInt8.init))
        let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        let session = try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + proof.ciphertext + proof.tag)
        // The first four audio bytes are data, never a BLE sequence number.
        let audio = Data([0x4f, 0x67, 0x67, 0x53, 0, 1, 2, 3, 4, 5])
        let box = try ChaChaPoly.seal(audio, using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        var wire = Data()
        wire.append(box.ciphertext)
        wire.append(box.tag)
        XCTAssertEqual(try session.decodeAudioFile(ciphertextAndTag: wire), audio)
        wire[wire.count - 1] ^= 1
        XCTAssertThrowsError(try session.decodeAudioFile(ciphertextAndTag: wire))
        XCTAssertThrowsError(try session.decodeAudioFile(ciphertextAndTag: Data(repeating: 0, count: 15)))
    }
    private func page(request: UInt32 = 99, total: UInt8, start: UInt8, session: UInt32, size: UInt32) -> Data {
        Data([1, 0x1a, 0] + le(request) + [total, 0, start, 0] + le(session) + le(size) + [2, 3])
    }
}
