import XCTest
@testable import VectaMLX
final class LibraryEvidenceTests:XCTestCase {
    let sources:[[String:Any]]=[["sourceID":"S1","text":"Согласовали перевод денег в пятницу."],["sourceID":"S2","text":"Запуск пока не утверждён."]]
    func paragraph(_ id:String,_ quote:String,_ allowed:[String]=["S1"]) -> [String:Any] {["sourceIDs":allowed,"text":"Дата решения 2026-10-11 (ошибочный пересказ)","evidence":[["sourceID":id,"quote":quote]]]}
    func testFallbackUsesVerifiedQuoteInsteadOfUnreviewedClaim() {
        let result=LibraryEvidence.fallback(paragraphs:[paragraph("S1","перевод денег в пятницу")],sources:sources)!
        let text=(result["paragraphs"] as! [[String:Any]])[0]["text"] as! String
        XCTAssertTrue(text.contains("перевод денег в пятницу"));XCTAssertFalse(text.contains("2026"))
    }
    func testRejectsFabricatedQuoteUnknownSourceAndCrossSourceClaim() {
        for p in [paragraph("S1","перевод денег в понедельник"),paragraph("S99","перевод денег в пятницу",["S99"]),paragraph("S2","Запуск пока не утверждён.")] {
            XCTAssertNil(LibraryEvidence.fallback(paragraphs:[p],sources:sources))
        }
    }
    func testReviewRequiresSourceEvidenceAndRejectsFalseQuotes() {
        let bad:[String:Any]=["schemaVersion":1,"status":"answered","paragraphs":[["text":"You never said this","sourceIDs":[String](),"evidence":[[String:Any]]()]]]
        XCTAssertFalse(LibraryEvidence.hasVerifiedEvidence(bad,sources:sources))
        let falseQuote:[String:Any]=["schemaVersion":1,"status":"answered","paragraphs":[paragraph("S1","перевод денег в понедельник")]]
        XCTAssertFalse(LibraryEvidence.hasVerifiedEvidence(falseQuote,sources:sources))
        var good=paragraph("S1","перевод денег в пятницу");good["text"]="перевод денег в пятницу"
        let literal:[String:Any]=["schemaVersion":1,"status":"answered","paragraphs":[good]]
        XCTAssertTrue(LibraryEvidence.hasVerifiedEvidence(literal,sources:sources))
    }
}
