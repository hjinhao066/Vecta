import Foundation

/// Recognized protocol families. Advertising alone never authorizes commands;
/// firmware version and signed handshake are independently checked by transport.
enum VectaDeviceModel: CaseIterable, Equatable {
    case note, notePin, notePro, notePinS
    private struct Descriptor {
        let prefix: String
        let title: String
    }
    private var descriptor: Descriptor {
        switch self {
        case .note: return Descriptor(prefix: "888", title: "Plaud Note")
        case .notePin: return Descriptor(prefix: "880", title: "Plaud NotePin")
        case .notePro: return Descriptor(prefix: "881", title: "Plaud Note Pro")
        case .notePinS: return Descriptor(prefix: "882", title: "Plaud NotePin S")
        }
    }
    init?(serialNumber: String) {
        guard serialNumber.utf8.count >= 3, serialNumber.utf8.count <= 128,
              let model = Self.allCases.first(where: { serialNumber.hasPrefix($0.descriptor.prefix) }) else { return nil }
        self = model
    }
    var serialNumberPrefix: String { descriptor.prefix }
    var displayName: String { descriptor.title }
}
