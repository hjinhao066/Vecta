import Foundation

/// Decodes the normal recorder manufacturer frame, including Apple's leading
/// company identifier. It does not parse Apple Find My advertisements.
/// Primary evidence: pinned iOS BleDevice.init(manufacturerData:) @0x77e94;
/// Android PkgUtils.convertManufacturerSpecificData2BleDevice (without company).
public struct NativeAdvertisement: Equatable {
    public enum SerialEncoding: Equatable { case text, hexadecimal }
    public let companyIdentifier: UInt16
    public let projectCode: UInt16
    public let firmwareType: String
    public let firmwareVersion: UInt32
    public let serialNumber: String
    public let serialEncoding: SerialEncoding
    public let protocolVersion: UInt16?
    public let bindState: UInt8?

    /// Modern project-code and legacy projectless firmware layouts are accepted.
    /// A caller must match the complete serial against the selected device;
    /// neither a local name nor a service UUID proves device identity.
    public static func decodeManufacturerData(_ data: Data) throws -> NativeAdvertisement {
        let bytes = Array(data)
        guard bytes.count >= 11, bytes.count <= 512 else {
            throw ProtocolWireError.malformedResponse
        }
        let company = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        // These are the explicit manufacturer branches in the Apple SDK.
        // Company0x004c (Apple Find My) deliberately cannot pass this parser.
        // 0x005d/projectless is observed on NotePin S. The pinned iOS
        // parser @0x78498 accepts unknown company IDs and @0x78504 handles
        // descriptor 4 without a project field. Keep a bounded known list;
        // exact serial/model matching below remains mandatory.
        guard [UInt16(0x0046), 0x0059, 0x0131, 0x005d].contains(company) else {
            throw ProtocolWireError.malformedResponse
        }
        let firmwareOffset: Int
        let project: UInt16
        if bytes[2] == 2, bytes.count >= 11, bytes[5] == 4 {
            firmwareOffset = 6
            project = UInt16(bytes[3]) | UInt16(bytes[4]) << 8
        } else if bytes[2] == 4 {
            firmwareOffset = 3
            project = 0
        } else { throw ProtocolWireError.malformedResponse }
        guard bytes[firmwareOffset] == 0x54 || bytes[firmwareOffset] == 0x56 else {
            throw ProtocolWireError.malformedResponse
        }
        let lengthOffset = firmwareOffset + 4
        let serialOffset = lengthOffset + 1
        let serialLength = Int(bytes[lengthOffset])
        guard [8, 9, 13, 16].contains(serialLength), bytes.count >= serialOffset + serialLength else {
            throw ProtocolWireError.malformedResponse
        }
        let serialBytes = Array(bytes[serialOffset..<(serialOffset + serialLength)])
        let serial: String
        let encoding: SerialEncoding
        if serialLength <= 9 {
            // iOS @0x78adc formats every byte as %02X, preserving leading0s.
            serial = serialBytes.map { String(format: "%02X", $0) }.joined()
            encoding = .hexadecimal
        } else {
            guard serialBytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
                  let decoded = String(bytes: serialBytes, encoding: .ascii) else {
                throw ProtocolWireError.malformedResponse
            }
            serial = decoded
            encoding = .text
        }
        let code = project
        // The SDK derives a missing model from the textual serial prefix.
        let derivedCode = code == 0 ? UInt16(serial.prefix(3)) ?? 0 : code
        guard derivedCode > 0 else { throw ProtocolWireError.malformedResponse }
        // Android manufacturer byte arrays exclude Apple's two-byte company ID.
        // protocol-ledger §6: fixed body offsets 18 (888/881) and 15 otherwise.
        // ASCII advertisements do not provide reliable version evidence.
        let versionOffset = ([UInt16(888), 881].contains(derivedCode) ? 18 : 15) + 2
        let port: UInt16? = encoding == .hexadecimal && bytes.count >= versionOffset + 2
            ? UInt16(bytes[versionOffset]) | UInt16(bytes[versionOffset + 1]) << 8 : nil
        let validPort = port.flatMap { $0 > 0 && $0 < 256 ? $0 : nil }
        let bind: UInt8? = bytes.count >= serialOffset + serialLength + 2 && bytes[bytes.count - 2] == 1
            ? bytes.last : nil
        return NativeAdvertisement(companyIdentifier: company, projectCode: derivedCode,
            firmwareType: String(UnicodeScalar(bytes[firmwareOffset])),
            firmwareVersion: UInt32(bytes[firmwareOffset + 1]) | UInt32(bytes[firmwareOffset + 2]) << 8 | UInt32(bytes[firmwareOffset + 3]) << 16,
            serialNumber: serial, serialEncoding: encoding, protocolVersion: validPort, bindState: bind)
    }
}

/// Selects a recorder from one normal manufacturer advertisement. A service
/// UUID, local name, or Apple Find My frame is not an identity signal. The
/// expected model and complete serial must both match the authorized target.
public enum NotePinAdvertisementMatcher {
    public static func match(
        manufacturerData: Data,
        expectedSerialNumber: String,
        expectedDeviceType: String
    ) -> NativeAdvertisement? {
        guard expectedDeviceType == "notepins",
              expectedSerialNumber.hasPrefix("882"),
              let advertisement = try? NativeAdvertisement.decodeManufacturerData(manufacturerData),
              advertisement.projectCode == 882,
              advertisement.serialNumber == expectedSerialNumber else {
            return nil
        }
        return advertisement
    }
}
