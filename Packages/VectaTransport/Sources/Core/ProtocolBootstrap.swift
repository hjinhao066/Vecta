import Foundation

/// Wire builders recovered by protocol research. Normal connection never
/// requests recovery; its separately named API is restricted to NotePin S.
public enum ProtocolBootstrap {
    /// BleAgentImpl.preFirstHandShake: decoded serial-signature bytes, chunks100.
    public static func signaturePackets(_ signature: Data) throws -> [Data] {
        try chunks(signature, command: 0xfe10)
    }

    /// Ledger section 2 documents recoveryConnectBleDevice's FE20 marker.
    /// Hardware effects and recording preservation remain unconfirmed.
    /// Requires the same account-issued serial signature as normal pairing.
    public static func recoverySignaturePackets(_ signature: Data, model: PlaudModel,
                                                 protocolVersion: UInt16) throws -> [Data] {
        guard model == .notePinS, (20...255).contains(protocolVersion) else {
            throw ProtocolWireError.invalidInput
        }
        return try chunks(signature, command: 0xfe20)
    }

    /// BleAgentImpl.sendRSAPublic sends the entire PEM text, not decoded DER.
    public static func publicKeyPackets(_ publicKeyPEM: String) throws -> [Data] {
        guard publicKeyPEM.hasPrefix("-----BEGIN PUBLIC KEY-----"),
              publicKeyPEM.contains("-----END PUBLIC KEY-----") else {
            throw ProtocolWireError.invalidInput
        }
        return try chunks(Data(publicKeyPEM.utf8), command: 0xfe12)
    }

    private static func chunks(_ payload: Data, command: UInt16) throws -> [Data] {
        let bytes = Array(payload)
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw ProtocolWireError.invalidInput }
        let count = (bytes.count + 99) / 100
        return (0..<count).map { index in
            let start = index * 100
            return Data([UInt8(truncatingIfNeeded: command), UInt8(command >> 8),
                         UInt8(count), UInt8(index)] + Array(bytes[start..<min(start + 100, bytes.count)]))
        }
    }

    /// Apple's existing SDK dataOfHandshake uses [01 01 00 01 01 checked],
    /// UTF8 token prefix32 and NUL padding. Preserve this owner's existing token.
    /// The Android client differs ([...02 00 checked], ASCII '0' padding).
    public static func ownerHandshake(token: String, checked: Bool) throws -> Data {
        let bytes = Array(token.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096,
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw ProtocolWireError.invalidInput
        }
        let owner = Array(bytes.prefix(32))
        return Data([1, 1, 0, 1, 1, checked ? 1 : 0] + owner
                    + Array(repeating: UInt8(0), count: 32 - owner.count))
    }

    /// iOS BleAgent.confirmHandShake additionally appends devToken prefix8,
    /// NUL padding, then the UTF8 byte length and bytes of an optional username.
    /// Values must come from the authorized account/partner response, never be
    /// invented. Nil uses the vendor's exact absent-value representation.
    public static func ownerConfirmation(token: String, developerToken: String? = nil,
                                         username: String? = nil) throws -> Data {
        let dev = Array((developerToken ?? "").utf8)
        let name = Array((username ?? "").utf8)
        guard dev.count <= 4096, dev.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
              name.count <= 255, name.allSatisfy({ $0 != 0 && $0 != 10 && $0 != 13 }) else {
            throw ProtocolWireError.invalidInput
        }
        var result = try ownerHandshake(token: token, checked: true)
        result.append(contentsOf: dev.prefix(8))
        result.append(Data(repeating: 0, count: max(0, 8 - dev.count)))
        result.append(UInt8(name.count))
        result.append(contentsOf: name)
        return result
    }

    public static func getState() -> Data { CommandPayload.getState() }

    /// The vendor calls this field uid, but SessionsHelper.init assigns current
    /// Unix seconds. It is a request-correlation ID, not the account user ID.
    public static func getFileList(requestID: UInt32, startSessionID: UInt32 = 0,
                                   onlyOne: Bool = false) -> Data {
        CommandPayload.getFileList(userID: requestID, sessionID: startSessionID, onlyOne: onlyOne)
    }
}
