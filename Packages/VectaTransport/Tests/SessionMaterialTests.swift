import CryptoKit
import XCTest
@testable import NotePinTransport

final class SessionMaterialTests: XCTestCase {
    private let key = Data((0x80...0x9f).map(UInt8.init))
    private let nonce = Data([7, 0, 0, 0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47])
    private let aad = Data([0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7])

    private func encrypt(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }
    private func material(proof: String = "PLAUD.AI") throws -> SessionMaterial {
        try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + encrypt(Data(proof.utf8)))
    }

    // RFC 8439 §2.8.2: external known-answer ciphertext and tag prove the
    // vendor separate representation is decoded correctly, beyond a roundtrip.
    func testRFC8439SeparateCiphertextAndTag() throws {
        let cipher = hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116")
        let tag = hex("1ae10b594f09e26a7e902ecbd0600691")
        let expected = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        XCTAssertEqual(try material().open(cipher + tag), expected)
    }

    func testRejectsShortRSAPlaintextAndWrongProof() throws {
        XCTAssertThrowsError(try SessionMaterial.authenticate(rsaPlaintext: Data(repeating: 0, count: 71)))
        XCTAssertThrowsError(try material(proof: "OTHER.AI")) { error in
            XCTAssertEqual(error as? TransportDecodeError, .invalidRecorderProof)
        }
    }
    func testRejectsModifiedAuthenticationTag() throws {
        var encrypted = try encrypt(Data([4, 3, 2, 1, 0x01, 0x03, 0]))
        encrypted[encrypted.count - 1] ^= 1
        XCTAssertThrowsError(try material().decodePacket(encrypted))
    }
    func testDecodesSequenceAndPreservesPayload() throws {
        let payload = Data([0x01, 0x03, 0, 0xff])
        let packet = try material().decodePacket(encrypt(Data([4, 3, 2, 1]) + payload))
        XCTAssertEqual(packet, ReceivedPacket(sequence: 0x01020304, payload: payload))
    }
    func testRejectsAuthenticatedPacketWithoutCompleteSequence() throws {
        XCTAssertThrowsError(try material().decodePacket(encrypt(Data([1, 2, 3]))))
    }
    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
}
