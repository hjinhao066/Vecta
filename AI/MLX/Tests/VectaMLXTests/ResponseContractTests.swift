import XCTest
@testable import VectaMLX
final class ResponseContractTests:XCTestCase {
    var plain:[String:Any] {["summary":"Публикацию отложили до проверки файлов.\n\nОтчёт подготовят к пятнице.","topics":["Передача файлов"],"decisions":["Отложить публикацию"],"tasks":[["description":"Подготовить отчёт"]],"uncertainties":[],"recordingTitle":"Этот слишком длинный заголовок из десяти слов не должен сохраняться"]}
    func testPreservesCompletePlainSummaryWithoutInventingClaims() {
        let input=plain,output=Worker.normalizedSummary(input)
        XCTAssertTrue(Worker.valid(output));XCTAssertEqual(output["summary"] as? String,input["summary"] as? String)
        let blocks=output["blocks"] as! [[String:Any]]
        XCTAssertEqual(blocks.count,2);XCTAssertEqual(blocks.map {($0["tokens"] as! [[String:Any]])[0]["text"] as! String}.joined(separator:"\n\n"),input["summary"] as? String)
        XCTAssertTrue(blocks.allSatisfy {$0["kind"] as? String == "inference" && $0["sourceSegments"] == nil})
        XCTAssertNil(input["blocks"]);XCTAssertNil(output["recordingTitle"])
    }
    func testCompactResponseAndThreeToSevenWordTitle() {
        let input:[String:Any] = ["summary":"Обсудили проверку передачи файлов.","recordingTitle":"Проверка передачи файлов перед публикацией","tasks":[[String:Any]]()]
        let output=Worker.normalizedSummary(input)
        XCTAssertTrue(Worker.valid(output))
        XCTAssertEqual(output["recordingTitle"] as? String,input["recordingTitle"] as? String)
        XCTAssertEqual(output["topics"] as? [String],[])
    }
    func testIncompleteRootRemainsFailure() {
        var input=plain;input.removeValue(forKey:"summary")
        XCTAssertFalse(Worker.valid(Worker.normalizedSummary(input)))
        input=plain;input.removeValue(forKey:"tasks")
        XCTAssertFalse(Worker.valid(Worker.normalizedSummary(input)))
    }
    func testExplicitEmptyBlocksAreNotSilentlyReplaced() {
        var input=plain;input["blocks"]=[[String:Any]]()
        XCTAssertFalse(Worker.valid(Worker.normalizedSummary(input)))
    }
    func testOptionalTaskMetadataDoesNotInventAssignment() {
        let output=Worker.normalizedSummary(plain)
        let task=(output["tasks"] as! [[String:Any]])[0]
        XCTAssertEqual(task["description"] as? String,"Подготовить отчёт")
        XCTAssertTrue(task["assignee"] is NSNull);XCTAssertTrue(task["deadline"] is NSNull)
    }
    func testPlainStreamIsLosslessAndTaskSectionDoesNotGuessMetadata() {
        let raw="Проверка файлов перед запуском\n\nОбсуждение\nПроверим передачу.\n\nПоручения\n- Подготовить отчёт к пятнице.\n\nОткрытые вопросы\n- Когда запускать?"
        let value=Worker.projectedPlainSummary(raw,assistant:false)
        XCTAssertEqual(value["summary"] as? String,raw)
        XCTAssertEqual(value["recordingTitle"] as? String,"Проверка файлов перед запуском")
        let tasks=value["tasks"] as! [[String:Any]]
        XCTAssertEqual(tasks.count,1);XCTAssertEqual(tasks[0]["description"] as? String,"Подготовить отчёт к пятнице.")
        XCTAssertTrue(tasks[0]["assignee"] is NSNull);XCTAssertTrue(tasks[0]["deadline"] is NSNull)
        XCTAssertTrue(Worker.plainTasks(raw,assistant:true).isEmpty)
        XCTAssertTrue(Worker.plainTasks("Предложения\n- Подготовить отчёт",assistant:false).isEmpty)
    }
}
