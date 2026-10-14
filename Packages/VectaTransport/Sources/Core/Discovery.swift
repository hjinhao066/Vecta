import Foundation

/// Discovery is evidence of a candidate only; it never establishes ownership,
/// authenticates the recorder, or promises that a file can be downloaded.
public struct NotePinCandidate: Equatable, Codable {
    public let identifier: UUID
    public let name: String?
    public let serviceUUIDs: [String]
    public let rssi: Int?
    public let alreadyConnected: Bool

    public init(identifier: UUID, name: String?, serviceUUIDs: [String], rssi: Int?, alreadyConnected: Bool) {
        self.identifier = identifier
        self.name = name
        self.serviceUUIDs = Array(Set(serviceUUIDs.map(NotePinGATT.canonicalUUID))).sorted()
        self.rssi = rssi
        self.alreadyConnected = alreadyConnected
    }

    public var isCandidate: Bool {
        let name = (name ?? "").lowercased()
        return serviceUUIDs.contains("1910") || name.contains("plaud") || name.contains("notepin")
    }
}

public struct DiscoveryInventory {
    public private(set) var candidates: [UUID: NotePinCandidate] = [:]
    public init() {}
    public mutating func observe(_ item: NotePinCandidate) {
        guard item.isCandidate || candidates[item.identifier] != nil else { return }
        let prior = candidates[item.identifier]
        candidates[item.identifier] = NotePinCandidate(
            identifier: item.identifier,
            name: item.name ?? prior?.name,
            serviceUUIDs: item.serviceUUIDs + (prior?.serviceUUIDs ?? []),
            rssi: item.rssi ?? prior?.rssi,
            alreadyConnected: item.alreadyConnected || (prior?.alreadyConnected ?? false)
        )
    }
}
