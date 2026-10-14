import XCTest
@testable import NotePinTransport

final class GATTProfileTests: XCTestCase {
    func testCanonicalizesBluetoothBaseUUIDWithoutChangingCustomUUID() {
        XCTAssertEqual(NotePinGATT.canonicalUUID("00001910-0000-1000-8000-00805f9b34fb"), "1910")
        XCTAssertEqual(NotePinGATT.canonicalUUID("1910"), "1910")
        XCTAssertEqual(NotePinGATT.canonicalUUID("00001910-1111-1000-8000-00805f9b34fb"), "00001910-1111-1000-8000-00805F9B34FB")
    }
    func testVendorProfileUsesRXForWritesAndTXForNotifications() {
        XCTAssertTrue(NotePinGATT.isControlProfile([
            GATTCharacteristic(service: "1910", uuid: "2BB0", canWrite: false, canNotify: true),
            GATTCharacteristic(service: "1910", uuid: "2BB1", canWrite: true, canNotify: false)]))
    }
    func testNameOrBatteryServiceDoesNotProveControlProfile() {
        XCTAssertFalse(NotePinGATT.isControlProfile([
            GATTCharacteristic(service: "180F", uuid: "2BB0", canWrite: false, canNotify: true),
            GATTCharacteristic(service: "180F", uuid: "2BB1", canWrite: true, canNotify: false)]))
        XCTAssertFalse(NotePinGATT.isControlProfile([]))
    }
    func testReversedPropertiesCannotPassProfileCheck() {
        XCTAssertFalse(NotePinGATT.isControlProfile([
            GATTCharacteristic(service: "1910", uuid: "2BB0", canWrite: true, canNotify: false),
            GATTCharacteristic(service: "1910", uuid: "2BB1", canWrite: false, canNotify: true)]))
    }
}
