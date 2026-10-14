import Foundation
import Security
import CryptoKit

// Synthetic only: no network, Bluetooth, Keychain, owner data or persistent keys.
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "OfflineAuthResearch", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
}
func der(_ tag: UInt8, _ bytes: Data) -> Data {
    let n = bytes.count
    let length: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)]
    return Data([tag] + length) + bytes
}
func exported(_ key: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let data = SecKeyCopyExternalRepresentation(key, &error) else {
        throw error!.takeRetainedValue() as Error
    }
    return data as Data
}
func pem(_ label: String, _ data: Data) -> String {
    "-----BEGIN \(label)-----\n" + data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END \(label)-----"
}
let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1, 0x05, 0])
for bits in [2048, 3072] {
    var error: Unmanaged<CFError>?
    let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits,
                                kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false]]
    guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
          let publicKey = SecKeyCopyPublicKey(privateKey) else { fatalError("local RSA generation failed") }
    let pkcs8 = der(0x30, Data([2, 1, 0]) + algorithm + der(4, try exported(privateKey)))
    let spki = der(0x30, algorithm + der(3, Data([0]) + (try exported(publicKey))))
    let imported = try PartnerRSAKey(pkcs8PEM: pem("PRIVATE KEY", pkcs8))
    let publicPackets = try ProtocolBootstrap.publicKeyPackets(pem("PUBLIC KEY", spki))
    let plain = Data((0..<80).map(UInt8.init))
    guard let cipher = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, plain as CFData, &error) else {
        fatalError("synthetic RSA encryption failed")
    }
    try require(try imported.decryptBootstrap(cipher as Data) == plain, "RSA roundtrip mismatch")
    try require(!publicPackets.isEmpty, "public-key framing empty")
    print("PASS local RSA \(bits): PKCS8 import, SPKI framing, synthetic PKCS1 decrypt; hardware acceptance UNKNOWN")
}
let key = Data((0..<32).map(UInt8.init)), nonce = Data(repeating: 7, count: 12), aad = Data(repeating: 9, count: 12)
let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: key),
                              nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
let material = try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + proof.ciphertext + proof.tag)
let a = Data([1, 3, 0, 10]), b = Data([1, 3, 0, 20])
let first = try material.sealPacket(sequence: 1, payload: a)
let second = try material.sealPacket(sequence: 2, payload: b)
let actualXOR = zip(first.dropLast(16), second.dropLast(16)).map { $0 ^ $1 }
let expectedXOR = zip(Data([1,0,0,0]) + a, Data([2,0,0,0]) + b).map { $0 ^ $1 }
try require(actualXOR == expectedXOR, "expected nonce reuse evidence absent")
print("CONFIRMED current SessionMaterial reuses keystream despite distinct sequence numbers (synthetic ciphertext XOR equals plaintext XOR)")
print("No device operations performed. No first pairing or offline reconnect established.")
