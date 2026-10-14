import XCTest
@testable import NotePinTransport

final class PartnerPlatformTests: XCTestCase {
    func testCredentialsCannotBeSentToAnArbitraryHost() {
        for domain in ["attacker.example", "platform-us.plaud.ai.attacker.example", "https://platform-us.plaud.ai", "platform-us.plaud.ai/path"] {
            XCTAssertThrowsError(try PartnerPlatform(domain: domain, accessToken: String(repeating: "x", count: 32)))
        }
    }
    func testRejectsHeaderInjectionAndEmptyToken() {
        for token in ["", String(repeating: "x", count: 32) + "\r\nInjected: value"] {
            XCTAssertThrowsError(try PartnerPlatform(domain: "platform-us.plaud.ai", accessToken: token))
        }
    }
    func testInvalidSerialIsRejectedBeforeAnyNetworkRequest() async throws {
        let client = try PartnerPlatform(domain: "platform-us.plaud.ai", accessToken: String(repeating: "x", count: 32))
        do { _ = try await client.prepare(serialNumber: "another-device", deviceType: "note")
            XCTFail("Invalid recorder identity must not reach network")
        } catch { XCTAssertEqual(error as? PartnerPlatformError, .invalidInput) }
    }
}
