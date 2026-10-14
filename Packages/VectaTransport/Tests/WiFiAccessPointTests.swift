import CryptoKit
import Foundation
import XCTest
@testable import NotePinTransport

/// Synthetic BLE responses only; no recorder, network association or credentials.
final class WiFiAccessPointTests: XCTestCase {
    private let serial = "882SYNTHETIC"
    private let header = Data([1, 0x0a, 0, 0])

    func testShortSuccessSelectsSDKSerialDefaultPassword() throws {
        let access = try ProtocolWiFiAccessPoint(response: header, serial: serial)
        XCTAssertEqual(access.ssid, "PlaudETIC")
        XCTAssertEqual(access.password, String(serial.suffix(8)))
    }

    func testSSIDVariantsAreDerivedFromEachSelectedDeviceNotAnyDisplayLabel() throws {
        for serial in ["882SYNTHETIC", "88212345678", "882ABCDEFGH", "882Ab12Cd34"] {
            let access = try ProtocolWiFiAccessPoint(response: header, serial: serial)
            XCTAssertEqual(access.ssidCandidates, ["Plaud" + serial.suffix(4), "PLAUD" + serial.suffix(4)])
            XCTAssertEqual(Set(access.ssidCandidates).count, 2)
            XCTAssertFalse(String(reflecting: access).contains(access.ssidCandidates[1]))
        }
    }

    func testShortSuccessUsesExactlyLastEightSerialCharacters() throws {
        for serial in ["882SYNTHETIC", "88212345678", "882ABCDEFGH"] {
            let access = try ProtocolWiFiAccessPoint(response: header, serial: serial)
            XCTAssertEqual(access.password, String(serial.suffix(8)))
            XCTAssertEqual(access.password.utf8.count, 8)
            XCTAssertFalse(String(reflecting: access).contains(access.password))
        }
    }

    func testEchoedPasswordTakesPrecedenceOverSerialDefault() throws {
        let access = try ProtocolWiFiAccessPoint(response: header + Data("Test1234".utf8), serial: serial)
        XCTAssertEqual(access.password, "Test1234")
        XCTAssertNotEqual(access.password, String(serial.suffix(8)))
    }

    func testPasswordResponseSelectsSuppliedPassword() throws {
        let access = try ProtocolWiFiAccessPoint(response: header + Data("Test1234".utf8), serial: serial)
        XCTAssertEqual(access.ssid, "PlaudETIC")
        XCTAssertEqual(access.password, "Test1234")
    }

    func testShortSuccessThroughModernBLEFramingIs24Bytes() throws {
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((32..<44).map(UInt8.init))
        let aad = Data((44..<56).map(UInt8.init))
        let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: key),
                                      nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        let session = try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + proof.ciphertext + proof.tag)
        let wire = try session.sealPacket(sequence: 7, payload: header)
        XCTAssertEqual(wire.count, 24)
        let response = try session.decodePacket(wire)
        XCTAssertEqual(try ProtocolWiFiAccessPoint(response: response.payload, serial: serial).password, String(serial.suffix(8)))
    }

    func testMalformedLengthsAndCommandsRejected() {
        for length in 0...14 where length != 4 && length != 12 {
            let response = length < 4 ? Data(header.prefix(length)) : header + Data(repeating: 65, count: length - 4)
            XCTAssertThrowsError(try ProtocolWiFiAccessPoint(response: response, serial: serial))
        }
        for response in [Data([0, 0x0a, 0, 0]), Data([1, 0x0d, 0, 0]), Data([1, 0x0a, 1, 0])] {
            XCTAssertThrowsError(try ProtocolWiFiAccessPoint(response: response, serial: serial))
        }
    }

    func testNonzeroStatusRejectedWithAndWithoutPassword() {
        for status: UInt8 in [1, 2, 255] {
            let rejected = Data([1, 0x0a, 0, status])
            for response in [rejected, rejected + Data("Test1234".utf8)] {
                XCTAssertThrowsError(try ProtocolWiFiAccessPoint(response: response, serial: serial))
            }
        }
    }

    func testInvalidPasswordAndUnsupportedSerialRejected() {
        for byte: UInt8 in [0, 10, 32, 127, 255] {
            XCTAssertThrowsError(try ProtocolWiFiAccessPoint(response: header + Data(repeating: byte, count: 8), serial: serial))
        }
        for value in ["", "881SYNTHETIC", "882bad\nserial"] {
            XCTAssertThrowsError(try ProtocolWiFiAccessPoint(response: header, serial: value))
        }
    }

    func testDataSliceAndCredentialRedaction() throws {
        var response = Data([0xaa, 0xbb]) + header + Data("Test1234".utf8)
        response.removeFirst(2)
        let access = try ProtocolWiFiAccessPoint(response: response, serial: serial)
        XCTAssertEqual(access.password, "Test1234")
        XCTAssertFalse(String(describing: access).contains(access.password))
        XCTAssertFalse(String(reflecting: access).contains(access.ssid))
    }
    func testWiFiCounterStartsIndependentlyAndRejectsStreamReplay() throws {
        var first = ProtocolWiFiReceiveSequence()
        try first.accept(1) // A preceding BLE counter of e.g. 100 must not reject this.
        try first.accept(2)
        XCTAssertThrowsError(try first.accept(2))
        XCTAssertThrowsError(try first.accept(1))
        XCTAssertEqual(first.last, 2)
        var reconnect = ProtocolWiFiReceiveSequence()
        try reconnect.accept(0)
        XCTAssertEqual(reconnect.last, 0)
        try reconnect.accept(UInt32.max)
        XCTAssertThrowsError(try reconnect.accept(0))
    }

    func testAbsentFeaturesUseFirmwareChaChaBaselineAndDoNotLeakAcrossSessions() throws {
        var first = ProtocolWiFiFeatures()
        XCTAssertFalse(first.received)
        XCTAssertEqual(first.cipher, .chaChaPoly)
        XCTAssertTrue(try first.accept(Data([1, 0x8a, 0, 8])))
        first.beginTransfer()
        let reconnect = ProtocolWiFiFeatures()
        XCTAssertFalse(reconnect.received)
        XCTAssertEqual(reconnect.cipher, .chaChaPoly)
    }

    func testAllFeatureBytesSelectOnlyBitThreeAndAcknowledgeOnce() throws {
        for flags in UInt8.min...UInt8.max {
            var features = ProtocolWiFiFeatures()
            let message = Data([1, 0x8a, 0, flags])
            XCTAssertTrue(try features.accept(message))
            XCTAssertEqual(features.cipher, flags & 8 == 0 ? .chaChaPoly : .aesGCM)
            XCTAssertFalse(try features.accept(message))
            features.beginTransfer()
            XCTAssertFalse(try features.accept(message))
        }
    }

    func testLateFeaturesBeforeAPReadinessCanSelectAES() throws {
        var features = ProtocolWiFiFeatures()
        XCTAssertEqual(features.cipher, .chaChaPoly)
        XCTAssertTrue(try features.accept(Data([1, 0x8a, 0, 8])))
        features.beginTransfer()
        XCTAssertEqual(features.cipher, .aesGCM)
    }

    func testLateCompatibleFeatureAfterAPReadinessIsAcknowledgedOnce() throws {
        var features = ProtocolWiFiFeatures()
        features.beginTransfer()
        XCTAssertTrue(try features.accept(Data([1, 0x8a, 0, 0])))
        XCTAssertFalse(try features.accept(Data([1, 0x8a, 0, 0])))
        XCTAssertEqual(features.cipher, .chaChaPoly)
    }

    func testConflictingLateFeatureCannotChangeActiveCipher() throws {
        var baseline = ProtocolWiFiFeatures()
        baseline.beginTransfer()
        XCTAssertThrowsError(try baseline.accept(Data([1, 0x8a, 0, 8])))
        XCTAssertEqual(baseline.cipher, .chaChaPoly)
        XCTAssertFalse(baseline.received)
        var aes = ProtocolWiFiFeatures()
        try aes.accept(Data([1, 0x8a, 0, 8]))
        aes.beginTransfer()
        XCTAssertThrowsError(try aes.accept(Data([1, 0x8a, 0, 0])))
        XCTAssertEqual(aes.cipher, .aesGCM)
    }

    func testExtendedAndSlicedFeaturesUseFirstFeatureByte() throws {
        var features = ProtocolWiFiFeatures()
        var message = Data([0xaa, 0xbb, 1, 0x8a, 0, 8, 0, 255])
        message.removeFirst(2)
        XCTAssertTrue(try features.accept(message))
        XCTAssertEqual(features.cipher, .aesGCM)
    }

    func testMalformedFeatureResponseDoesNotAlterSelection() throws {
        for message in [Data(), Data([1, 0x8a, 0]), Data([1, 0x8b, 0, 8]), Data([0, 0x8a, 0, 8]), Data([1, 0x8a, 1, 8]), Data([1, 0x8a, 0]) + Data(repeating: 0, count: 4094)] {
            var features = ProtocolWiFiFeatures()
            XCTAssertThrowsError(try features.accept(message))
            XCTAssertEqual(features.cipher, .chaChaPoly)
            XCTAssertFalse(features.received)
        }
    }

}
