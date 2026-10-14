import Foundation

/// AP-open success may omit the password even for a protected AP. The official
/// SDK uses the serial's last eight characters when firmware omits the password.
public struct ProtocolWiFiAccessPoint: CustomStringConvertible, CustomDebugStringConvertible {
    public let ssid: String
    public let password: String
    // Verified firmware naming variants; suffix comes from this authenticated device.
    public var ssidCandidates: [String] { [ssid, "PLAUD" + ssid.suffix(4)] }
    public var description: String { "Recorder WiFi access point (credentials redacted)" }
    public var debugDescription: String { description }

    public init(response: Data, serial: String) throws {
        let payload = Data(response)
        guard payload.count == 4 || payload.count == 12,
              payload.prefix(3) == Data([1, 0x0a, 0]), payload[3] == 0 else {
            throw ProtocolWireError.malformedResponse
        }
        _ = try SavedPlaudDevice(serialNumber: serial, model: .notePinS, protocolVersion: 20)
        ssid = "Plaud" + serial.suffix(4)
        if payload.count == 4 {
            let fallback = String(serial.suffix(8))
            guard fallback.utf8.count == 8, fallback.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
                throw ProtocolWireError.invalidInput
            }
            password = fallback
        } else {
            let bytes = payload.dropFirst(4)
            guard bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
                  let value = String(data: bytes, encoding: .ascii) else {
                throw ProtocolWireError.malformedResponse
            }
            password = value
        }
    }
}

/// The firmware baseline is ChaChaPoly; 8A is an optional feature announcement.
/// Once the AP is ready, a late announcement cannot change an active packet cipher.
public struct ProtocolWiFiFeatures {
    public private(set) var cipher: WiFiPacketCipher = .chaChaPoly
    public private(set) var received = false
    private var locked = false
    public init() {}

    /// Returns true only for the first valid announcement, to acknowledge it once.
    @discardableResult public mutating func accept(_ response: Data) throws -> Bool {
        let payload = Data(response)
        guard (4...4096).contains(payload.count), payload.prefix(3) == Data([1, 0x8a, 0]) else {
            throw ProtocolWireError.malformedResponse
        }
        let selected: WiFiPacketCipher = payload[3] & 0x08 != 0 ? .aesGCM : .chaChaPoly
        guard !locked || selected == cipher else { throw ProtocolWireError.inconsistentPage }
        let first = !received
        cipher = selected; received = true
        return first
    }

    public mutating func beginTransfer() { locked = true }
}

/// Incoming WiFi sequence state is scoped to this channel, not prior BLE replies.
/// Only call after authenticated packet decryption; reject replay within the stream.
public struct ProtocolWiFiReceiveSequence {
    public private(set) var last: UInt32?
    public init() {}
    public mutating func accept(_ sequence: UInt32) throws {
        guard last == nil || sequence > last! else { throw ProtocolWireError.inconsistentPage }
        last = sequence
    }
}
