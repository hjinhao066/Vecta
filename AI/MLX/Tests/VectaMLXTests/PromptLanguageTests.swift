import XCTest
@testable import VectaMLX

final class PromptLanguageTests: XCTestCase {
    func testAbsentOutputLanguagePreservesRussianPromptSelection() throws {
        let language = try OutputLanguage.resolve(nil)
        XCTAssertEqual(language, .russian)
        XCTAssertEqual(SummaryPrompt.instruction(for: language), SummaryPrompt.instruction)
        XCTAssertEqual(SummaryPrompt.userPrefix(for: language), SummaryPrompt.userPrefix)
        XCTAssertEqual(SummaryPrompt.userSuffix(for: language), SummaryPrompt.userSuffix)
        XCTAssertEqual(LibraryPrompt.extraction(for: language), LibraryPrompt.extraction)
        XCTAssertEqual(LibraryPrompt.instruction(for: language), LibraryPrompt.instruction)
        XCTAssertEqual(SemanticPrompt.instruction(for: language), SemanticPrompt.instruction)
    }

    func testEnglishPromptSelectionKeepsContractsAndRequiresEnglishOutput() throws {
        let language = try OutputLanguage.resolve("en")
        XCTAssertEqual(language, .english)
        XCTAssertTrue(SummaryPrompt.instruction(for: language).contains("in English"))
        XCTAssertTrue(SummaryPrompt.userPrefix(for: language).contains("TRANSCRIPT"))
        XCTAssertTrue(LibraryPrompt.extraction(for: language).contains("VERBATIM"))
        XCTAssertTrue(LibraryPrompt.instruction(for: language).contains("sourceIDs"))
        XCTAssertTrue(SemanticPrompt.instruction(for: language).contains("schemaVersion"))
        XCTAssertTrue(SemanticPrompt.instruction(for: language).contains("in English"))
    }

    func testOnlySupportedSerializedLanguagesAreAccepted() throws {
        XCTAssertEqual(try OutputLanguage.resolve("ru"), .russian)
        XCTAssertEqual(try OutputLanguage.resolve("en"), .english)
        XCTAssertThrowsError(try OutputLanguage.resolve("de"))
        XCTAssertThrowsError(try OutputLanguage.resolve(42))
    }
}
