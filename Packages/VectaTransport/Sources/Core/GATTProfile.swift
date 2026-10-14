import Foundation

public enum NotePinGATT {
    public static let service = "1910"
    // TX/RX in the SDK are named from the recorder's perspective.
    // Android sendData explicitly writes RX, NOT TX.
    public static let notifications = "2BB0"
    public static let commands = "2BB1"

    public static func canonicalUUID(_ string: String) -> String {
        let upper = string.uppercased()
        let suffix = "-0000-1000-8000-00805F9B34FB"
        if upper.count == 36, upper.hasPrefix("0000"), upper.hasSuffix(suffix) {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }

    public static func isControlProfile(_ characteristics: [GATTCharacteristic]) -> Bool {
        let scoped = characteristics.filter { canonicalUUID($0.service) == service }
        return scoped.contains { canonicalUUID($0.uuid) == notifications && $0.canNotify }
            && scoped.contains { canonicalUUID($0.uuid) == commands && $0.canWrite }
    }
}

public struct GATTCharacteristic: Codable, Equatable {
    public let service: String
    public let uuid: String
    public let canWrite: Bool
    public let canNotify: Bool
    public let properties: UInt
    public init(service: String, uuid: String, canWrite: Bool, canNotify: Bool, properties: UInt = 0) {
        self.service = service
        self.uuid = uuid
        self.canWrite = canWrite
        self.canNotify = canNotify
        self.properties = properties
    }
}
