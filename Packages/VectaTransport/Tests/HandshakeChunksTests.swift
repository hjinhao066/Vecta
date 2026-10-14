import XCTest
@testable import NotePinTransport

final class HandshakeChunksTests: XCTestCase {
    func testOutOfOrderChunksAndDuplicateReassembleInIndexOrder() throws {
        var decoder = HandshakeChunks()
        XCTAssertNil(try decoder.accept(Data([0x12, 0xfe, 3, 2, 5, 6])))
        XCTAssertNil(try decoder.accept(Data([0x12, 0xfe, 3, 0, 1, 2])))
        XCTAssertNil(try decoder.accept(Data([0x12, 0xfe, 3, 0, 1, 2])))
        XCTAssertEqual(try decoder.accept(Data([0x12, 0xfe, 3, 1, 3, 4])), Data([1, 2, 3, 4, 5, 6]))
    }
    func testRejectsConflictingDuplicateAndChangedCount() throws {
        var decoder = HandshakeChunks()
        _ = try decoder.accept(Data([0x12, 0xfe, 2, 0, 1]))
        XCTAssertThrowsError(try decoder.accept(Data([0x12, 0xfe, 2, 0, 2])))
        XCTAssertThrowsError(try decoder.accept(Data([0x12, 0xfe, 3, 1, 2])))
    }
    func testRejectsMalformedHeadersWithoutPoisoningState() throws {
        var decoder = HandshakeChunks()
        for bytes: [UInt8] in [[], [0x12, 0xfe, 1, 0], [0x12, 0xfe, 0, 0, 1],
            [0x12, 0xfe, 1, 1, 1], [0x10, 0xfe, 1, 0, 1]] {
            XCTAssertThrowsError(try decoder.accept(Data(bytes)))
        }
        XCTAssertEqual(try decoder.accept(Data([0x12, 0xfe, 1, 0, 42])), Data([42]))
    }
    func testPayloadLimitCannotBeExceeded() throws {
        var decoder = HandshakeChunks(maximumPayloadBytes: 2)
        _ = try decoder.accept(Data([0x12, 0xfe, 2, 0, 1, 2]))
        XCTAssertThrowsError(try decoder.accept(Data([0x12, 0xfe, 2, 1, 3])))
    }
}
