import CryptoKit
import Foundation
import XCTest
@testable import NotePinTransport

/// Synthetic AEAD/framing coverage only. Fixed firmware nonce use is preserved;
/// these tests neither establish device acceptance nor claim a nonce-reuse fix.
final class WiFiSessionMaterialTests: XCTestCase {
    private let keyBytes = Data((0..<32).map(UInt8.init))
    private let nonceBytes = Data((32..<44).map(UInt8.init))
    private let aad = Data((44..<56).map(UInt8.init))
    private let ciphers: [WiFiPacketCipher] = [.chaChaPoly, .aesGCM]

    private func session() throws -> SessionMaterial {
        let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: keyBytes),
                                       nonce: ChaChaPoly.Nonce(data: nonceBytes), authenticating: aad)
        return try SessionMaterial.authenticate(rsaPlaintext: keyBytes + nonceBytes + aad + proof.ciphertext + proof.tag)
    }

    func testVersionTwoHelloThroughAuthenticatedFraming() throws {
        let material = try session()
        let hello = try WiFiEnvelope(command: .sayHello, json: Data("{\"sn\":\"882SYNTHETIC\",\"pVer\":20}".utf8), version: 2)
        for cipher in ciphers {
            let packet = try material.sealWiFiPacket(sequence: 1, payload: hello.encoded(), cipher: cipher)
            let decoded = try material.decodeWiFiPacket(packet, cipher: cipher)
            XCTAssertEqual(try WiFiEnvelope.decode(decoded.payload), hello)
            XCTAssertEqual(try WiFiEnvelope.decode(decoded.payload).metadata(as: WiFiSayHello.self).sn, "882SYNTHETIC")
        }
    }

    func testAuthenticatedSDKTranscriptFromTokenOnlyHelloToNonemptyFile() throws {
        let material = try session()
        for cipher in ciphers {
            var sequence = ProtocolWiFiReceiveSequence()
            func receive(_ envelope: WiFiEnvelope, counter: UInt32) throws -> WiFiEnvelope {
                let wire = try material.sealWiFiPacket(sequence: counter, payload: envelope.encoded(), cipher: cipher)
                let packet = try material.decodeWiFiPacket(wire, cipher: cipher)
                try sequence.accept(packet.sequence)
                return try WiFiEnvelope.decode(packet.payload)
            }
            let hello = try receive(WiFiEnvelope(command: .sayHello, json: Data("{\"token\":\"152314bcf440f78d369fabb1c8f4e0af\",\"pVer\":1}".utf8), version: 2), counter: 1)
            XCTAssertTrue(try hello.metadata(as: WiFiSayHello.self).matches(serial: "882SYNTHETIC"))
            let request = try WiFiEnvelope(metadata: WiFiHandshake(token: "synthetic-owner", stamp: 1))
            XCTAssertEqual(try request.encoded()[3], 1)
            let handshake = try receive(WiFiEnvelope(metadata: WiFiHandshakeResponse(status: 0)), counter: 2)
            XCTAssertTrue(try handshake.metadata(as: WiFiHandshakeResponse.self).accepted)
            let file = WiFiRecordingFile(session: 9, size: 3, scene: 0)
            var list = try WiFiFileListCollector(expectedFiles: [file], expectedUID: 7)
            let page = try receive(WiFiEnvelope(metadata: WiFiListResponse(status: 0, count: 1, offset: 0, uid: 7),
                                               binary: Data([9, 0, 0, 0, 3, 0, 0, 0, 0, 0])), counter: 3)
            XCTAssertEqual(try list.accept(page), [file])
            var collector = try WiFiFileCollector(expectedSession: file.session, expectedSize: file.size)
            let acknowledgment = try receive(WiFiEnvelope(command: .download, json: Data("{\"status\":0,\"session\":9}".utf8), version: 2), counter: 4)
            try collector.begin(acknowledgment)
            let content = try receive(WiFiEnvelope(metadata: WiFiContentMetadata(session: 9, offset: 0, length: 3, last: 1), binary: Data([1, 2, 3])), counter: 5)
            XCTAssertEqual(try collector.accept(content), Data([1, 2, 3]))
            try collector.finish()
            XCTAssertThrowsError(try receive(content, counter: 5))
        }
    }

    private func independentlySeal(_ plaintext: Data, cipher: WiFiPacketCipher, additionalData: Data? = nil) throws -> Data {
        switch cipher {
        case .chaChaPoly:
            let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: keyBytes),
                                         nonce: ChaChaPoly.Nonce(data: nonceBytes), authenticating: additionalData ?? aad)
            return Data(box.ciphertext) + Data(box.tag)
        case .aesGCM:
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyBytes),
                                      nonce: AES.GCM.Nonce(data: nonceBytes), authenticating: additionalData ?? aad)
            return Data(box.ciphertext) + Data(box.tag)
        }
    }

    private func independentlyOpen(_ ciphertextAndTag: Data, cipher: WiFiPacketCipher) throws -> Data {
        switch cipher {
        case .chaChaPoly:
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceBytes),
                                              ciphertext: ciphertextAndTag.dropLast(16), tag: ciphertextAndTag.suffix(16))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: keyBytes), authenticating: aad)
        case .aesGCM:
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes),
                                           ciphertext: ciphertextAndTag.dropLast(16), tag: ciphertextAndTag.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: keyBytes), authenticating: aad)
        }
    }

    func testAuthenticatedBootstrapProofIsRequiredForEitherCipher() throws {
        _ = try session()
        let invalidProof = try independentlySeal(Data("NOT-A-RECORDER".utf8), cipher: .chaChaPoly)
        XCTAssertThrowsError(try SessionMaterial.authenticate(rsaPlaintext: keyBytes + nonceBytes + aad + invalidProof)) {
            XCTAssertEqual($0 as? TransportDecodeError, .invalidRecorderProof)
        }
        var damagedProof = try independentlySeal(Data("PLAUD.AI".utf8), cipher: .chaChaPoly)
        damagedProof[damagedProof.count - 1] ^= 1
        XCTAssertThrowsError(try SessionMaterial.authenticate(rsaPlaintext: keyBytes + nonceBytes + aad + damagedProof))
        XCTAssertThrowsError(try SessionMaterial.authenticate(rsaPlaintext: Data(repeating: 0, count: 71)))
    }

    func testBothCiphersRoundTripLargeEnvelopeAndLESequenceWithoutNoncePrefix() throws {
        let material = try session()
        let binary = Data((0..<8192).map { UInt8($0 & 255) })
        let envelope = try WiFiEnvelope(metadata: WiFiContentMetadata(session: 9, offset: 0, length: 8192, last: 1),
                                        binary: binary)
        let pdu = try envelope.encoded()
        XCTAssertGreaterThan(pdu.count, 4096)
        for cipher in ciphers {
            let packet = try material.sealWiFiPacket(sequence: 0x12345678, payload: pdu, cipher: cipher)
            XCTAssertEqual(packet.startIndex, 0)
            XCTAssertEqual(packet.count, pdu.count + 4 + 16)
            let plaintext = try independentlyOpen(packet, cipher: cipher)
            XCTAssertEqual(plaintext, Data([0x78, 0x56, 0x34, 0x12]) + pdu)
            let decoded = try material.decodeWiFiPacket(packet, cipher: cipher)
            XCTAssertEqual(decoded, ReceivedPacket(sequence: 0x12345678, payload: pdu))
            XCTAssertEqual(try WiFiEnvelope.decode(decoded.payload), envelope)
            // SessionMaterial handles ciphertext Data slices with nonzero indices.
            var slice = Data([0xaa, 0xbb]) + packet
            slice.removeFirst(2)
            XCTAssertEqual(try material.decodeWiFiPacket(slice, cipher: cipher), decoded)
        }
    }

    func testIndependentCiphertextDecodesSequenceExtremes() throws {
        let material = try session()
        let pdu = try WiFiEnvelope(metadata: WiFiHeartbeat()).encoded()
        for cipher in ciphers {
            for sequence: UInt32 in [0, 1, UInt32.max] {
                let prefix = Data((0..<4).map { UInt8((sequence >> ($0 * 8)) & 255) })
                let packet = try independentlySeal(prefix + pdu, cipher: cipher)
                XCTAssertEqual(try material.decodeWiFiPacket(packet, cipher: cipher), ReceivedPacket(sequence: sequence, payload: pdu))
                XCTAssertEqual(try material.sealWiFiPacket(sequence: sequence, payload: pdu, cipher: cipher), packet)
            }
        }
    }

    func testCiphertextAndTagTamperingWrongCipherAndWrongAADReject() throws {
        let material = try session()
        let pdu = try WiFiEnvelope(metadata: WiFiHeartbeat()).encoded()
        for cipher in ciphers {
            let packet = try material.sealWiFiPacket(sequence: 7, payload: pdu, cipher: cipher)
            // Sequence prefix, payload, first/last tag byte are all authenticated.
            for index in [0, 4, packet.count - 16, packet.count - 1] {
                var corrupt = packet
                corrupt[index] ^= 1
                XCTAssertThrowsError(try material.decodeWiFiPacket(corrupt, cipher: cipher))
            }
            let other: WiFiPacketCipher
            switch cipher {
            case .chaChaPoly: other = .aesGCM
            case .aesGCM: other = .chaChaPoly
            }
            XCTAssertThrowsError(try material.decodeWiFiPacket(packet, cipher: other))
            let wrongAAD = try independentlySeal(Data([7, 0, 0, 0]) + pdu, cipher: cipher,
                                                 additionalData: Data(repeating: 0, count: 12))
            XCTAssertThrowsError(try material.decodeWiFiPacket(wrongAAD, cipher: cipher))
        }
    }

    func testWiFiPayloadUpperBoundDoesNotWrapAndDecodeHasMatchingBound() throws {
        let material = try session()
        let maximum = 0xffffff
        let payload = Data(repeating: 0xa5, count: maximum)
        for cipher in ciphers {
            XCTAssertThrowsError(try material.sealWiFiPacket(sequence: 0, payload: Data(), cipher: cipher))
            XCTAssertThrowsError(try material.sealWiFiPacket(sequence: 0, payload: Data(repeating: 0, count: maximum + 1), cipher: cipher)) {
                XCTAssertEqual($0 as? TransportDecodeError, .malformedEncryptedPacket)
            }
            let packet = try material.sealWiFiPacket(sequence: UInt32.max, payload: payload, cipher: cipher)
            XCTAssertEqual(packet.count, maximum + 20)
            let decoded = try material.decodeWiFiPacket(packet, cipher: cipher)
            XCTAssertEqual(decoded.sequence, UInt32.max)
            XCTAssertEqual(decoded.payload, payload)
            XCTAssertThrowsError(try material.decodeWiFiPacket(packet + Data([0]), cipher: cipher)) {
                XCTAssertEqual($0 as? TransportDecodeError, .malformedEncryptedPacket)
            }
        }
    }

    func testShortCiphertextTagsAndAuthenticatedEmptyPayloadReject() throws {
        let material = try session()
        for cipher in ciphers {
            for count in 0..<20 {
                XCTAssertThrowsError(try material.decodeWiFiPacket(Data(repeating: 0, count: count), cipher: cipher)) {
                    XCTAssertEqual($0 as? TransportDecodeError, .malformedEncryptedPacket)
                }
            }
            // A correctly authenticated sequence with no PDU must still fail.
            let noPayload = try independentlySeal(Data([1, 0, 0, 0]), cipher: cipher)
            XCTAssertEqual(noPayload.count, 20)
            XCTAssertThrowsError(try material.decodeWiFiPacket(noPayload, cipher: cipher)) {
                XCTAssertEqual($0 as? TransportDecodeError, .malformedEncryptedPacket)
            }
            let packet = try material.sealWiFiPacket(sequence: 1, payload: Data([1]), cipher: cipher)
            XCTAssertEqual(try material.decodeWiFiPacket(packet, cipher: cipher).payload, Data([1]))
            for missing in 1...16 {
                XCTAssertThrowsError(try material.decodeWiFiPacket(Data(packet.dropLast(missing)), cipher: cipher))
            }
            XCTAssertThrowsError(try material.decodeWiFiPacket(packet + Data([0]), cipher: cipher))
        }
    }

    func testBLESealCapRemains4096AndWiFiHasSeparateLargerCap() throws {
        let material = try session()
        let allowed = Data(repeating: 1, count: 4096)
        let larger = Data(repeating: 2, count: 4097)
        XCTAssertEqual(try material.decodePacket(material.sealPacket(sequence: 2, payload: allowed)),
                       ReceivedPacket(sequence: 2, payload: allowed))
        XCTAssertThrowsError(try material.sealPacket(sequence: 2, payload: larger)) {
            XCTAssertEqual($0 as? TransportDecodeError, .malformedEncryptedPacket)
        }
        XCTAssertThrowsError(try material.sealPacket(sequence: 2, payload: Data()))
        for cipher in ciphers {
            let packet = try material.sealWiFiPacket(sequence: 2, payload: larger, cipher: cipher)
            XCTAssertEqual(try material.decodeWiFiPacket(packet, cipher: cipher), ReceivedPacket(sequence: 2, payload: larger))
        }
    }
}
