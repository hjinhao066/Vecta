import XCTest
@testable import NotePinTransport
final class FileDeletionTests: XCTestCase {
    func ack(_ session: UInt32, status: UInt8 = 0) -> Data {
        Data([1, 31, 0] + (0..<4).map { UInt8(truncatingIfNeeded: session >> ($0 * 8)) } + [status])
    }
    func testWireFormatAndResponseCorrelation() throws {
        XCTAssertEqual(try ProtocolFileDeletion.request(sessionID: 0x12345678), Data([1,30,0,0x78,0x56,0x34,0x12]))
        XCTAssertThrowsError(try ProtocolFileDeletion.request(sessionID: 0))
        XCTAssertEqual(try ProtocolFileDeletion.response(ack(42, status: 2), version: 20, expectedSession: 42), 2)
        XCTAssertThrowsError(try ProtocolFileDeletion.response(ack(42), version: 20, expectedSession: 43))
        XCTAssertThrowsError(try ProtocolFileDeletion.response(Data([1,30,0,0]), version: 20, expectedSession: 42))
        XCTAssertThrowsError(try ProtocolFileDeletion.response(ack(42).dropLast(), version: 20, expectedSession: 42))
        XCTAssertThrowsError(try ProtocolFileDeletion.response(ack(42), version: 6, expectedSession: 42))
    }
    func testAcknowledgementsAndFreshEmptyListRequiredBeforeUnlink() throws {
        var plan = try ProtocolDeletionPlan(sessions: [41,42])
        XCTAssertThrowsError(try plan.confirmEmpty([]))
        XCTAssertEqual(try plan.next(), 41)
        XCTAssertThrowsError(try plan.next())
        XCTAssertThrowsError(try plan.acknowledge(ack(42), version: 20))
        XCTAssertEqual(plan.awaiting, 41)
        try plan.acknowledge(ack(41), version: 20)
        XCTAssertEqual(try plan.next(), 42)
        XCTAssertThrowsError(try plan.acknowledge(ack(42, status: 1), version: 20))
        XCTAssertThrowsError(try plan.confirmEmpty([]))
        try plan.acknowledge(ack(42), version: 20)
        XCTAssertNil(try plan.next())
        XCTAssertThrowsError(try plan.confirmEmpty([43]))
        XCTAssertNoThrow(try plan.confirmEmpty([]))
    }
    func testEmptyListStillNeedsVerificationAndInvalidListsAreRejected() throws {
        var plan = try ProtocolDeletionPlan(sessions: [])
        XCTAssertNil(try plan.next())
        XCTAssertThrowsError(try plan.confirmEmpty([1]))
        XCTAssertNoThrow(try plan.confirmEmpty([]))
        XCTAssertThrowsError(try ProtocolDeletionPlan(sessions: [0]))
        XCTAssertThrowsError(try ProtocolDeletionPlan(sessions: [1,1]))
    }
}
