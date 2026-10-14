import XCTest
@testable import NotePinTransport
final class ListRetryTests: XCTestCase {
    func testBoundedRetryAndSafety() {
        var p=ProtocolListRetryPolicy()
        XCTAssertFalse(p.takeRetry(authenticated:false,connected:true,writePending:false))
        XCTAssertFalse(p.takeRetry(authenticated:true,connected:false,writePending:false))
        XCTAssertFalse(p.takeRetry(authenticated:true,connected:true,writePending:true))
        XCTAssertEqual(p.retries,0)
        for _ in 0..<2 { XCTAssertTrue(p.takeRetry(authenticated:true,connected:true,writePending:false)) }
        XCTAssertFalse(p.takeRetry(authenticated:true,connected:true,writePending:false))
    }
    func testFreshSnapshotNeverCombinesPartialLists() throws {
        let a=ProtocolRecordingFile(sessionID:1,byteSize:10,scene:0,attribute:0)
        let b=ProtocolRecordingFile(sessionID:2,byteSize:20,scene:0,attribute:0)
        var first=ProtocolFileListCollector(requestID:1)
        XCTAssertNil(try first.accept(.init(requestID:1,total:2,startIndex:0,files:[a])))
        var retry=ProtocolFileListCollector(requestID:2)
        XCTAssertThrowsError(try retry.accept(.init(requestID:1,total:2,startIndex:1,files:[b])))
        XCTAssertNil(try retry.accept(.init(requestID:2,total:2,startIndex:1,files:[b])))
        XCTAssertEqual(try retry.accept(.init(requestID:2,total:2,startIndex:0,files:[a])),[a,b])
        XCTAssertEqual(retry.receivedCount,2)
        XCTAssertEqual(try retry.accept(.init(requestID:2,total:2,startIndex:0,files:[a])),[a,b])
    }
}
