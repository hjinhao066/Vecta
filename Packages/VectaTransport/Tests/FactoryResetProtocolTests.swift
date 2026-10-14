import XCTest
@testable import NotePinTransport

/// Payload/state checks only. No BLE, recorder reset, credentials or cloud API.
final class FactoryResetProtocolTests: XCTestCase {
    func testConfirmedSupportedPayload() throws {
        XCTAssertEqual(try ProtocolFactoryReset.payload(serial: "882SYNTHETIC", confirmedSerial: "882SYNTHETIC",
            model: .notePinS, protocolVersion: 20), Data([1, 0x66, 0]))
    }
    func testDifferentOrEmptyConfirmationRejected() {
        for serial in ["", "882OTHER", "882SYNTHETIC "] {
            XCTAssertThrowsError(try ProtocolFactoryReset.payload(serial: "882SYNTHETIC", confirmedSerial: serial,
                model: .notePinS, protocolVersion: 20))
        }
    }
    func testUnsupportedModelsAndVersionsRejected() {
        for model in PlaudModel.allCases where model != .notePinS {
            let serial = String(model.projectCode) + "SYNTHETIC"
            XCTAssertThrowsError(try ProtocolFactoryReset.payload(serial: serial, confirmedSerial: serial,
                model: model, protocolVersion: 20))
        }
        for version: UInt16 in [0, 10, 19, 21, 255] {
            XCTAssertThrowsError(try ProtocolFactoryReset.payload(serial: "882SYNTHETIC", confirmedSerial: "882SYNTHETIC",
                model: .notePinS, protocolVersion: version))
        }
    }
    func testMalformedOrWrongModelSerialRejected() {
        for serial in ["881SYNTHETIC", "882bad\nserial", "882/invalid", String(repeating: "8", count: 129)] {
            XCTAssertThrowsError(try ProtocolFactoryReset.payload(serial: serial, confirmedSerial: serial,
                model: .notePinS, protocolVersion: 20))
        }
    }
    func testDeliveryAndDisconnectionAreSeparateEvidence() throws {
        var observation = FactoryResetObservation()
        try observation.request()
        XCTAssertEqual(observation.state, .requested)
        XCTAssertFalse(observation.finish(disconnected: true))
        XCTAssertTrue(observation.acknowledge())
        XCTAssertEqual(observation.state, .delivered)
        XCTAssertTrue(observation.finish(disconnected: true))
        XCTAssertEqual(observation.state, .finished(disconnected: true))
    }
    func testObservationTimeoutIsNotReportedAsDisconnection() throws {
        var observation = FactoryResetObservation()
        try observation.request()
        XCTAssertTrue(observation.acknowledge())
        XCTAssertTrue(observation.finish(disconnected: false))
        XCTAssertEqual(observation.state, .finished(disconnected: false))
    }
    func testDuplicateCallbacksAndRequestsRejected() throws {
        var observation = FactoryResetObservation()
        XCTAssertFalse(observation.acknowledge())
        XCTAssertFalse(observation.finish(disconnected: false))
        try observation.request()
        XCTAssertThrowsError(try observation.request())
        XCTAssertTrue(observation.acknowledge())
        XCTAssertFalse(observation.acknowledge())
        XCTAssertTrue(observation.finish(disconnected: true))
        XCTAssertFalse(observation.finish(disconnected: false))
        XCTAssertThrowsError(try observation.request())
    }
    func testCancellationRejectsLateEvidenceWithoutRetry() throws {
        for delivered in [false, true] {
            var observation = FactoryResetObservation()
            try observation.request()
            if delivered { XCTAssertTrue(observation.acknowledge()) }
            observation.cancel()
            XCTAssertEqual(observation.state, .cancelled)
            XCTAssertFalse(observation.acknowledge())
            XCTAssertFalse(observation.finish(disconnected: true))
            XCTAssertThrowsError(try observation.request())
        }
    }
    func testStopPreservesCompletedObservation() throws {
        var observation = FactoryResetObservation()
        try observation.request()
        XCTAssertTrue(observation.acknowledge())
        XCTAssertTrue(observation.finish(disconnected: false))
        observation.cancel()
        XCTAssertEqual(observation.state, .finished(disconnected: false))
    }
}
