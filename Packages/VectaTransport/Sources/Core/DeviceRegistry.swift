import Foundation

public enum PlaudModel: String, Codable, CaseIterable {
    case note, notePin, notePro, notePinS
    public var projectCode: UInt16 { switch self { case .note: return 888; case .notePin: return 880; case .notePro: return 881; case .notePinS: return 882 } }
    public var displayName: String { switch self { case .note: return "Plaud Note"; case .notePin: return "Plaud NotePin"; case .notePro: return "Plaud Note Pro"; case .notePinS: return "Plaud NotePin S" } }
    // Partner type for the original models is not established by the three
    // sources. Never invent a cloud endpoint parameter for them.
    public var partnerType: String? { switch self { case .notePro: return "notepro"; case .notePinS: return "notepins"; default: return nil } }
    public static func identify(project: UInt16, serial: String) -> Self? {
        guard let prefix = UInt16(serial.prefix(3)), prefix == project else { return nil }
        return allCases.first { $0.projectCode == project }
    }
}

public enum PlaudProtocolMode: String, Codable { case plaintext, authenticatedEncryption }
public struct PlaudProtocolProfile: Equatable {
    public let version: UInt16
    public var mode: PlaudProtocolMode { version >= 20 ? .authenticatedEncryption : .plaintext }
    public var sessionInData: Bool { version >= 7 }
    public var tokenWidth: Int { version >= 9 ? 32 : 16 }
    public var supportsBatteryCommand: Bool { version >= 5 }
    public init(version: UInt16) throws {
        guard version > 0, version < 256 else { throw ProtocolWireError.invalidInput }
        self.version = version
    }
    // Android wire profile documented independently by protocol-ledger §5.5
    // and physical NB100 §05. Apple encrypted path retains its existing builder.
    public func ownerHandshake(token: String, checked: Bool) throws -> Data {
        guard !token.isEmpty, token.utf8.count <= 4096,
              token.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else { throw ProtocolWireError.invalidInput }
        var bytes: [UInt8] = [1, 1, 0, 2, 0]
        if version >= 3 { bytes.append(checked ? 1 : 0) }
        let owner = Array(token.utf8.prefix(tokenWidth))
        bytes += owner + Array(repeating: UInt8(0x30), count: tokenWidth - owner.count)
        if checked { bytes += Array(repeating: 0, count: 9) }
        return Data(bytes)
    }
}

public struct PlaudCandidate: Identifiable, Equatable {
    public let id: UUID
    public let advertisement: NativeAdvertisement?
    public let rssi: Int
    public let isConnectable: Bool
    public var model: PlaudModel? { advertisement.flatMap { PlaudModel.identify(project: $0.projectCode, serial: $0.serialNumber) } }
    public var displayName: String { model?.displayName ?? "Unknown Plaud model" }
    public var maskedSerial: String { advertisement.map { "••••" + $0.serialNumber.suffix(4) } ?? "Not detected" }
    public var canConnect: Bool { isConnectable && model != nil && advertisement?.protocolVersion != nil }
    public init(id: UUID, advertisement: NativeAdvertisement?, rssi: Int, isConnectable: Bool) {
        self.id = id; self.advertisement = advertisement; self.rssi = rssi; self.isConnectable = isConnectable
    }
    public static func observe(id: UUID, manufacturer: Data?, name: String?, services: [String], rssi: Int, connectable: Bool) -> Self? {
        if let manufacturer, let parsed = try? NativeAdvertisement.decodeManufacturerData(manufacturer) {
            return Self(id: id, advertisement: parsed, rssi: rssi, isConnectable: connectable)
        }
        // Evidence-only candidate. No identity means no command can be sent.
        let hint = name?.lowercased() ?? ""
        let bytes = manufacturer.map(Array.init) ?? []
        let company = bytes.count >= 2 ? UInt16(bytes[0]) | UInt16(bytes[1]) << 8 : 0
        let vendorHint = [UInt16(0x0046), 0x0059, 0x0131, 0x005d].contains(company)
        guard hint.contains("plaud") || hint.contains("notepin") || vendorHint || services.contains(where: { NotePinGATT.canonicalUUID($0) == "1910" }) else { return nil }
        return Self(id: id, advertisement: nil, rssi: rssi, isConnectable: connectable)
    }
}

public struct SavedPlaudDevice: Codable, Equatable {
    public let serialNumber: String
    public let model: PlaudModel
    public let protocolVersion: UInt16
    public let lastSynchronized: Date?
    /// Learned after exact advertisement identity and successful auth/list.
    public let peripheralID: UUID?
    public init(serialNumber: String, model: PlaudModel, protocolVersion: UInt16, lastSynchronized: Date? = nil, peripheralID: UUID? = nil) throws {
        guard serialNumber.count <= 128,
              serialNumber.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) || $0 == 0x2d || $0 == 0x5f }),
              PlaudModel.identify(project: model.projectCode, serial: serialNumber) == model else { throw ProtocolWireError.invalidInput }
        _ = try PlaudProtocolProfile(version: protocolVersion)
        self.serialNumber = serialNumber; self.model = model; self.protocolVersion = protocolVersion; self.lastSynchronized = lastSynchronized; self.peripheralID = peripheralID
    }
    public func matches(_ candidate: PlaudCandidate) -> Bool {
        candidate.model == model && candidate.advertisement?.serialNumber == serialNumber && candidate.isConnectable
    }
}

/// This store changes only Vecta's local selection. No BLE/cloud unbind.
public final class PlaudSelectionStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> SavedPlaudDevice? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ProtocolWireError.invalidInput }
        let value = try JSONDecoder().decode(SavedPlaudDevice.self, from: Data(contentsOf: url))
        return try SavedPlaudDevice(serialNumber: value.serialNumber, model: value.model, protocolVersion: value.protocolVersion, lastSynchronized: value.lastSynchronized, peripheralID: value.peripheralID)
    }
    public func save(_ device: SavedPlaudDevice) throws {
        _ = try SavedPlaudDevice(serialNumber: device.serialNumber, model: device.model, protocolVersion: device.protocolVersion, lastSynchronized: device.lastSynchronized, peripheralID: device.peripheralID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw ProtocolWireError.invalidInput }
        if FileManager.default.fileExists(atPath: url.path) {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ProtocolWireError.invalidInput }
        }
        try JSONEncoder().encode(device).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func forget() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = url.appendingPathExtension("retired")
        if FileManager.default.fileExists(atPath: marker.path) {
            let properties = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ProtocolWireError.invalidInput }
        }
        try Data("Local selection intentionally removed; do not restore from migration.\n".utf8).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
