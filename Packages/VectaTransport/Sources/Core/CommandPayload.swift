import Foundation

/// Experimental, unencrypted command payloads recovered from the vendor's
/// iOS SDK. These are NOT wire packets. No Bluetooth write API is exposed.
/// Framing, authentication and encryption must be verified before sending.
public enum CommandPayload {
    public static func getState() -> Data { Data([0x01, 0x03, 0x00]) }

    public static func getFileList(userID: UInt32, sessionID: UInt32, onlyOne: Bool) -> Data {
        var bytes: [UInt8] = [0x01, 0x1a, 0x00]
        bytes += littleEndian(userID)
        bytes += littleEndian(sessionID)
        bytes.append(onlyOne ? 1 : 0)
        return Data(bytes)
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
