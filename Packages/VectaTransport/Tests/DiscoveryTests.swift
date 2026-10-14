import XCTest
@testable import NotePinTransport
final class DiscoveryTests: XCTestCase {
    func testUnrelatedBatteryPeripheralIsNotRecorder() {
        var inventory = DiscoveryInventory()
        inventory.observe(.init(identifier: UUID(), name: "Mouse", serviceUUIDs: ["180F"], rssi: -42, alreadyConnected: false))
        XCTAssertTrue(inventory.candidates.isEmpty)
    }
    func testServiceAndNameAreIndependentDiscoveryEvidence() {
        XCTAssertTrue(NotePinCandidate(identifier: UUID(), name: nil, serviceUUIDs: ["1910"], rssi: nil, alreadyConnected: false).isCandidate)
        XCTAssertTrue(NotePinCandidate(identifier: UUID(), name: "PLAUD NotePin S", serviceUUIDs: [], rssi: -50, alreadyConnected: false).isCandidate)
    }
    func testDuplicateAdvertisementsPreserveConnectionAndServiceEvidence() {
        let id = UUID()
        var inventory = DiscoveryInventory()
        inventory.observe(.init(identifier: id, name: "NotePin S", serviceUUIDs: ["1910"], rssi: nil, alreadyConnected: true))
        inventory.observe(.init(identifier: id, name: nil, serviceUUIDs: ["180f"], rssi: -61, alreadyConnected: false))
        XCTAssertEqual(inventory.candidates.count, 1)
        XCTAssertEqual(inventory.candidates[id]?.name, "NotePin S")
        XCTAssertEqual(inventory.candidates[id]?.serviceUUIDs, ["180F", "1910"])
        XCTAssertEqual(inventory.candidates[id]?.rssi, -61)
        XCTAssertEqual(inventory.candidates[id]?.alreadyConnected, true)
    }
}
