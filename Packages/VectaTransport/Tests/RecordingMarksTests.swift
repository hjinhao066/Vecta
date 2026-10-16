import XCTest
@testable import NotePinTransport

final class RecordingMarksTests: XCTestCase {
    private func page(_ session: UInt32 = 123, total: UInt8 = 1, index: UInt8 = 0, points: [UInt32]) -> Data {
        var data = ProtocolRecordingMarks.request(session: session)
        data.append(contentsOf: [0, total, index, UInt8(points.count)])
        for point in points { data.append(contentsOf: [UInt8(truncatingIfNeeded: point), UInt8(truncatingIfNeeded: point >> 8), UInt8(truncatingIfNeeded: point >> 16), UInt8(truncatingIfNeeded: point >> 24)]) }
        return data
    }
    func testPinnedReadOnlyRequest() {
        XCTAssertEqual(ProtocolRecordingMarks.request(session: 0x12345678), Data([1,0x23,0,0x78,0x56,0x34,0x12]))
    }
    func testRawValuesPreserved() throws {
        let result = try ProtocolRecordingMarksPage.decode(page(points: [0, 12345, .max]))
        XCTAssertEqual(result.session, 123); XCTAssertEqual(result.points, [0,12345,.max])
    }
    func testEmptyAndRejected() throws {
        var empty = ProtocolRecordingMarks.request(session: 123); empty.append(contentsOf: [0,0])
        XCTAssertEqual(try ProtocolRecordingMarksPage.decode(empty).points, [])
        XCTAssertEqual(try ProtocolRecordingMarksPage.decode(empty + Data([0,0])).points, [])
        var rejected = ProtocolRecordingMarks.request(session: 123); rejected.append(1)
        XCTAssertEqual(try ProtocolRecordingMarksPage.decode(rejected).status, 1)
    }
    func testMalformedLengthsAndHeaders() throws {
        let valid = page(points: [12])
        for length in 0..<valid.count { XCTAssertThrowsError(try ProtocolRecordingMarksPage.decode(valid.prefix(length))) }
        XCTAssertThrowsError(try ProtocolRecordingMarksPage.decode(valid + Data([0])))
        var wrong = valid; wrong[1] = 0x24
        XCTAssertThrowsError(try ProtocolRecordingMarksPage.decode(wrong))
        XCTAssertThrowsError(try ProtocolRecordingMarksPage.decode(page(total: 1, index: 1, points: [])))
    }
    func testPageCountNotItemCountAndOutOfOrder() throws {
        var collector = ProtocolRecordingMarksCollector(session: 123)
        let later = try ProtocolRecordingMarksPage.decode(page(total: 2, index: 1, points: [30,40]))
        XCTAssertNil(try collector.accept(later)); XCTAssertNil(try collector.accept(later))
        XCTAssertEqual(try collector.accept(ProtocolRecordingMarksPage.decode(page(total: 2, points: [10]))), [10,30,40])
    }
    func testMismatchedSessionAndConflictingPagesRejected() throws {
        var collector = ProtocolRecordingMarksCollector(session: 123)
        XCTAssertThrowsError(try collector.accept(ProtocolRecordingMarksPage.decode(page(124, points: [1]))))
        XCTAssertNil(try collector.accept(ProtocolRecordingMarksPage.decode(page(total: 2, points: [1]))))
        XCTAssertThrowsError(try collector.accept(ProtocolRecordingMarksPage.decode(page(total: 2, points: [2]))))
        XCTAssertThrowsError(try collector.accept(ProtocolRecordingMarksPage.decode(page(total: 3, points: [1]))))
    }
}
