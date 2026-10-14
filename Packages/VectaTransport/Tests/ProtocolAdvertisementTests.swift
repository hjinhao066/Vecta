import XCTest
@testable import NotePinTransport

final class ProtocolAdvertisementTests: XCTestCase {
    func testTextSerialFrameDoesNotDependOnLocalNameOrAdvertisedServices() throws {
        // Synthetic normal NotePin S layout; no user-device fixture.
        let serial = "882SYNTHETIC0"
        let frame = Data([0x46, 0, 2, 0x72, 3, 4, 0x56, 0x56, 0x34, 0x12, 13] + Array(serial.utf8) + [1, 0])
        let decoded = try NativeAdvertisement.decodeManufacturerData(frame)
        XCTAssertEqual(decoded.companyIdentifier, 0x46)
        XCTAssertEqual(decoded.projectCode, 882)
        XCTAssertEqual(decoded.firmwareType, "V")
        XCTAssertEqual(decoded.firmwareVersion, 0x123456)
        XCTAssertEqual(decoded.serialNumber, serial)
        XCTAssertEqual(decoded.serialEncoding, .text)
        let different = "882SYNTHETIC1"
        XCTAssertNotEqual(decoded.serialNumber, different) // exact owner target matters
    }

    func testBinarySerialKeepsLeadingZerosAndUppercaseHex() throws {
        let frame = Data([0x59, 0, 2, 0x70, 3, 4, 0x54, 1, 0, 0, 8, 0, 1, 2, 0xab, 0xcd, 0xef, 0, 9])
        let decoded = try NativeAdvertisement.decodeManufacturerData(frame)
        XCTAssertEqual(decoded.serialNumber, "000102ABCDEF0009")
        XCTAssertEqual(decoded.serialEncoding, .hexadecimal)
        XCTAssertEqual(decoded.projectCode, 880)
    }

    func testFindMyMalformedAndUnverifiedLayoutsCannotSelectADevice() throws {
        let base = Data([0x46, 0, 2, 0x72, 3, 4, 0x56, 1, 0, 0, 13] + Array("882SYNTHETIC0".utf8))
        var findMy = base
        findMy[0] = 0x4c
        XCTAssertThrowsError(try NativeAdvertisement.decodeManufacturerData(findMy))
        for position in [2, 5, 6, 10] {
            var bad = base
            bad[position] = 0xff
            XCTAssertThrowsError(try NativeAdvertisement.decodeManufacturerData(bad))
        }
        for count in 0..<base.count {
            XCTAssertThrowsError(try NativeAdvertisement.decodeManufacturerData(base.prefix(count)))
        }
        var invalidText = base
        invalidText[11] = 0
        XCTAssertThrowsError(try NativeAdvertisement.decodeManufacturerData(invalidText))
    }

    func testLegacyProjectlessBinarySerialSelectsOnlyExactTarget() throws {
        // Synthetic payload in the SDK's descriptor-4 branch, observed on
        // real NotePin S with company 0x005d; no private serial in fixture.
        let frame = Data([0x5d, 0, 4, 0x56, 7, 2, 1, 8, 0x88, 0x20, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        let decoded = try NativeAdvertisement.decodeManufacturerData(frame)
        XCTAssertEqual(decoded.serialNumber, "8820AABBCCDDEEFF")
        XCTAssertEqual(decoded.projectCode, 882)
        XCTAssertEqual(decoded.firmwareVersion, 0x010207)
        XCTAssertNotNil(NotePinAdvertisementMatcher.match(manufacturerData: frame,
            expectedSerialNumber: "8820AABBCCDDEEFF", expectedDeviceType: "notepins"))
        XCTAssertNil(NotePinAdvertisementMatcher.match(manufacturerData: frame,
            expectedSerialNumber: "8820AABBCCDDEE00", expectedDeviceType: "notepins"))
        for length in 0..<frame.count {
            XCTAssertThrowsError(try NativeAdvertisement.decodeManufacturerData(frame.prefix(length)))
        }
        var findMy = frame; findMy[0] = 0x4c
        XCTAssertThrowsError(try NativeAdvertisement.decodeManufacturerData(findMy))
    }

    func testMatcherRequiresExactSerialAndNotePinSModel() throws {
        let serial = "882SYNTHETIC0"
        let frame = Data([0x46, 0, 2, 0x72, 3, 4, 0x56, 0x56, 0x34, 0x12, 13] + Array(serial.utf8))
        XCTAssertNotNil(NotePinAdvertisementMatcher.match(
            manufacturerData: frame, expectedSerialNumber: serial, expectedDeviceType: "notepins"))
        XCTAssertNil(NotePinAdvertisementMatcher.match(
            manufacturerData: frame, expectedSerialNumber: "882SYNTHETIC1", expectedDeviceType: "notepins"))
        XCTAssertNil(NotePinAdvertisementMatcher.match(
            manufacturerData: frame, expectedSerialNumber: serial, expectedDeviceType: "notepro"))
        var findMy = frame
        findMy[0] = 0x4c
        XCTAssertNil(NotePinAdvertisementMatcher.match(
            manufacturerData: findMy, expectedSerialNumber: serial, expectedDeviceType: "notepins"))
    }
}
