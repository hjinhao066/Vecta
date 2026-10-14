import XCTest
@testable import NotePinTransport

final class CommandPayloadTests: XCTestCase {
    // Independent expected bytes from SDK ARM64 disassembly, not a device
    // capture. These tests prove payload encoding only, not BLE compatibility.
    func testGetStateMatchesRecoveredVendorPayload() {
        XCTAssertEqual(CommandPayload.getState(), Data([0x01, 0x03, 0x00]))
    }

    func testFileListUsesLittleEndianIntegers() {
        XCTAssertEqual(CommandPayload.getFileList(userID: 0x01020304,
            sessionID: 0x05060708, onlyOne: false),
            Data([0x01, 0x1a, 0x00, 4, 3, 2, 1, 8, 7, 6, 5, 0]))
    }

    func testFileListMaximumIntegerAndSingleSessionFlag() {
        XCTAssertEqual(CommandPayload.getFileList(userID: .max, sessionID: 0, onlyOne: true),
            Data([0x01, 0x1a, 0x00, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 1]))
    }
}
