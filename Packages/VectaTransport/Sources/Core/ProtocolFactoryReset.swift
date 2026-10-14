import Foundation

/// Explicit reset only; never part of connection, sync, recovery or retries.
/// This payload does not establish cloud-account unbinding or reset completion.
public enum ProtocolFactoryReset {
    public static func payload(serial: String, confirmedSerial: String, model: PlaudModel,
                               protocolVersion: UInt16) throws -> Data {
        guard serial == confirmedSerial, model == .notePinS, protocolVersion == 20 else {
            throw ProtocolWireError.invalidInput
        }
        _ = try SavedPlaudDevice(serialNumber: serial, model: model, protocolVersion: protocolVersion)
        return Data([0x01, 0x66, 0x00])
    }
}

/// One-shot transport evidence. Delivery/disconnection never imply erased data.
public struct FactoryResetObservation {
    public enum State: Equatable { case ready, requested, delivered, finished(disconnected: Bool), cancelled }
    public private(set) var state = State.ready
    public init() {}
    public mutating func request() throws {
        guard state == .ready else { throw ProtocolWireError.invalidInput }
        state = .requested
    }
    @discardableResult public mutating func acknowledge() -> Bool {
        guard state == .requested else { return false }
        state = .delivered
        return true
    }
    @discardableResult public mutating func finish(disconnected: Bool) -> Bool {
        guard state == .delivered else { return false }
        state = .finished(disconnected: disconnected)
        return true
    }
    public mutating func cancel() {
        switch state {
        case .ready, .requested, .delivered: state = .cancelled
        case .finished, .cancelled: break
        }
    }
}
