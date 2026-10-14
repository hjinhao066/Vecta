import XCTest
@testable import VectaMLX

final class SemanticStreamTests:XCTestCase {
    let prefix="{\"schemaVersion\":1,\"title\":\"Report\",\"entries\":["
    let entry="{\"id\":\"one\",\"kind\":\"insight\",\"title\":\"Topic\",\"tokens\":[{\"text\":\"Braces } [ and \\\"quotes\\\"\"}]}"
    func testIncompleteCardAndEscapedStrings() {
        XCTAssertNil(SemanticStream.snapshot(prefix+String(entry.dropLast())))
        let result=SemanticStream.snapshot(prefix+entry+",{\"id\":\"two\",\"tokens\":[{\"text\":\"unfinished")
        XCTAssertEqual((result?["entries"] as? [[String:Any]])?.count,1)
        XCTAssertEqual(result?["sourcePolicy"] as? String,"none")
    }
    func testCompleteResultAndMalformedStructure() {
        XCTAssertEqual((SemanticStream.snapshot(prefix+entry+","+entry+"]}")?["entries"] as? [[String:Any]])?.count,2)
        XCTAssertNil(SemanticStream.snapshot(prefix+"]}"))
        XCTAssertNil(SemanticStream.snapshot(prefix+"}"+entry))
    }
    func testRecoverableAliasesStreamWithoutSchemaOrTitle() throws {
        let raw="{\"cards\":[{\"body\":\"Complete card\"},{\"body\":\"unfinished"
        XCTAssertEqual((SemanticStream.snapshot(raw)?["cards"] as? [[String:Any]])?.count,1)
        XCTAssertTrue(Worker.recoverableSemantic(["sections":[["text":"A","role":"question"]]]))
        XCTAssertFalse(Worker.recoverableSemantic(["entries":[]]))
    }
    func testFormattingNeverTriggersSemanticRegeneration() {
        XCTAssertNotNil(Worker.semanticResponse("```json\n{bad json}\n```"))
        XCTAssertNotNil(Worker.semanticResponse("A useful prose response"))
        XCTAssertNotNil(Worker.semanticResponse("{\"entries\":[],\"role\":\"wrong\"}"))
        XCTAssertNil(Worker.semanticResponse(" \n\t"))
    }
    func testKindCannotBeUsedAsRole() throws {
        var value=try XCTUnwrap(SemanticStream.snapshot(prefix+entry+"]}"))
        var entries=value["entries"] as! [[String:Any]]
        entries[0]["role"]="question";value["entries"]=entries
        XCTAssertFalse(Worker.validSemantic(value))
        entries[0]["role"]="position";value["entries"]=entries
        XCTAssertTrue(Worker.validSemantic(value))
    }
    func testInventedSpeakerIsRejectedWhenInputHasNoIDs() throws {
        var value=try XCTUnwrap(SemanticStream.snapshot(prefix+entry+"]}"))
        var entries=value["entries"] as! [[String:Any]]
        entries[0]["tokens"]=[["text":"A claim "],["speakerID":"invented"]]
        value["entries"]=entries
        XCTAssertFalse(Worker.validSemantic(value,speakers:[]))
        XCTAssertTrue(Worker.validSemantic(value,speakers:["invented"]))
    }
}
