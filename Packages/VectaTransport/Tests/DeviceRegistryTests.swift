import XCTest
@testable import NotePinTransport

final class DeviceRegistryTests: XCTestCase {
    func testIncompleteVendorAndNotePinNameStayVisibleWithoutCommandPermission() {
        for candidate in [
            PlaudCandidate.observe(id: UUID(), manufacturer: Data([0x5d, 0, 4]), name: nil, services: [], rssi: -40, connectable: true),
            PlaudCandidate.observe(id: UUID(), manufacturer: nil, name: "NotePin", services: [], rssi: -40, connectable: true)
        ] {
            XCTAssertNotNil(candidate)
            XCTAssertNil(candidate?.model)
            XCTAssertFalse(candidate?.canConnect ?? true)
        }
        XCTAssertNil(PlaudCandidate.observe(id: UUID(), manufacturer: Data([0x4c, 0, 0x12]), name: nil, services: [], rssi: -40, connectable: false))
    }
    private func binaryCandidate(_ model: PlaudModel, suffix: UInt8 = 0xaa) throws -> PlaudCandidate {
        let first: UInt8 = 0x88
        let second: UInt8 = model == .note ? 0x80 : model == .notePin ? 0x00 : model == .notePro ? 0x10 : 0x20
        var body: [UInt8] = [4, 0x56, 1, 0, 0, 8, first, second, suffix, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let offset = model == .note || model == .notePro ? 18 : 15
        body += Array(repeating: 0, count: offset - body.count)
        body += [10, 0, 1, 0]
        let advertisement = try NativeAdvertisement.decodeManufacturerData(Data([0x5d, 0] + body))
        return PlaudCandidate(id: UUID(), advertisement: advertisement, rssi: -35, isConnectable: true)
    }
    func testBinaryAdvertisementsForAllModelsAndDifferentDevices() throws {
        for model in PlaudModel.allCases {
            let first = try binaryCandidate(model)
            let second = try binaryCandidate(model, suffix: 0x11)
            XCTAssertEqual(first.model, model)
            XCTAssertEqual(first.advertisement?.protocolVersion, 10)
            XCTAssertTrue(first.canConnect)
            XCTAssertNotEqual(first.advertisement?.serialNumber, second.advertisement?.serialNumber)
            XCTAssertFalse(first.maskedSerial.contains(first.advertisement!.serialNumber))
        }
    }
    func testCleanSelectionSwitchForgetAndCorruptedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("selected.json")
        let store = PlaudSelectionStore(url: url)
        XCTAssertNil(try store.load())
        let first = try binaryCandidate(.note)
        let second = try binaryCandidate(.notePin)
        for candidate in [first, second] {
            let saved = try SavedPlaudDevice(serialNumber: candidate.advertisement!.serialNumber,
                model: candidate.model!, protocolVersion: 10)
            try store.save(saved)
            XCTAssertEqual(try store.load(), saved)
        }
        XCTAssertFalse(try store.load()!.matches(first))
        try store.forget()
        XCTAssertNil(try store.load())
        try Data("corrupted".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }
    func testAllKnownProjectCodesResolveToDistinctModels() {
        let values: [(UInt16, String, PlaudModel)] = [
            (888, "888SYNTHETIC", .note), (880, "880SYNTHETIC", .notePin),
            (881, "881SYNTHETIC", .notePro), (882, "882SYNTHETIC", .notePinS)
        ]
        for (project, serial, expected) in values {
            XCTAssertEqual(PlaudModel.identify(project: project, serial: serial), expected)
        }
        XCTAssertNil(PlaudModel.identify(project: 888, serial: "881SYNTHETIC"))
        XCTAssertNil(PlaudModel.identify(project: 999, serial: "999SYNTHETIC"))
    }

    func testUnknownCandidateIsVisibleButCannotConnect() {
        let candidate = PlaudCandidate.observe(id: UUID(), manufacturer: nil, name: "PLAUD", services: [], rssi: -40, connectable: true)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.displayName, "Неизвестная модель Plaud")
        XCTAssertFalse(candidate?.canConnect ?? true)
    }

    func testSavedIdentityMatchesExactSerialAndModel() throws {
        let saved = try SavedPlaudDevice(serialNumber: "882SYNTHETIC0", model: .notePinS, protocolVersion: 20)
        let frame = Data([0x46, 0, 2, 0x72, 3, 4, 0x56, 0x56, 0x34, 0x56, 13] + Array("882SYNTHETIC0".utf8))
        let advertisement = try NativeAdvertisement.decodeManufacturerData(frame)
        let candidate = PlaudCandidate(id: UUID(), advertisement: advertisement, rssi: -30, isConnectable: true)
        XCTAssertTrue(saved.matches(candidate))
        let otherFrame = Data([0x46, 0, 2, 0x72, 3, 4, 0x56, 0x56, 0x34, 0x56, 13] + Array("882SYNTHETIC1".utf8))
        let other = PlaudCandidate(id: UUID(), advertisement: try NativeAdvertisement.decodeManufacturerData(otherFrame), rssi: -30, isConnectable: true)
        XCTAssertFalse(saved.matches(other))
    }

    func testVerifiedPeripheralCachePersistsAndOldSelectionMigrates() throws {
        let id = UUID()
        let saved = try SavedPlaudDevice(serialNumber: "882SYNTHETIC0", model: .notePinS, protocolVersion: 20, peripheralID: id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("selected.json")
        let store = PlaudSelectionStore(url: url)
        try store.save(saved)
        XCTAssertEqual(try store.load()?.peripheralID, id)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "peripheralID")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        XCTAssertNil(try store.load()?.peripheralID)
        XCTAssertEqual(try store.load()?.serialNumber, saved.serialNumber)
        try store.forget()
        XCTAssertNil(try store.load())
    }

    func testLegacyProfileDoesNotInventModernEncryption() throws {
        let profile = try PlaudProtocolProfile(version: 9)
        XCTAssertEqual(profile.mode, .plaintext)
        XCTAssertEqual(profile.tokenWidth, 32)
        XCTAssertEqual(try profile.ownerHandshake(token: "token", checked: false).prefix(5), Data([1, 1, 0, 2, 0]))
    }
}
