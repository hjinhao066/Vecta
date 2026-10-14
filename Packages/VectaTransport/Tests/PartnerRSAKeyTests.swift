import Foundation
import Security
import XCTest
@testable import NotePinTransport

final class PartnerRSAKeyTests: XCTestCase {
    func testImportsPKCS8AndDecryptsPKCS1BootstrapWithNativeSecurity() throws {
        // Generate a disposable, memory-only test key; no private key fixture
        // or user credential is stored in the repository or logs.
        // Select the modern Security implementation on macOS rather than the
        // legacy CDSA generator. The key remains explicitly nonpersistent.
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false,
            kSecUseDataProtectionKeychain: true]
        var generationError: Unmanaged<CFError>?
        let candidate = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError)
        let generationDiagnostic = (generationError?.takeRetainedValue()).map {
            "\(CFErrorGetDomain($0) as String):\(CFErrorGetCode($0))"
        } ?? "no Security error"
        let generated = try XCTUnwrap(candidate, generationDiagnostic)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(generated))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(generated, nil)) as Data
        let algorithm = tlv(0x30, Data([6, 9, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1, 5, 0]))
        let pkcs8 = tlv(0x30, Data([2, 1, 0]) + algorithm + tlv(4, pkcs1))
        let imported = try PartnerRSAKey(pkcs8PEM: pem(pkcs8))
        let expected = Data("disposable bootstrap test bytes".utf8)
        let cipher = try XCTUnwrap(SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, expected as CFData, nil)) as Data
        XCTAssertEqual(try imported.decryptBootstrap(cipher), expected)
        XCTAssertThrowsError(try imported.decryptBootstrap(Data([1, 2, 3])))
    }
    func testRejectsMalformedPEMAndUnsupportedAlgorithm() {
        for bad in ["not a PEM", "-----BEGIN \( "PRIVATE KEY" )-----\n%%%\n-----END \( "PRIVATE KEY" )-----"] {
            XCTAssertThrowsError(try PartnerRSAKey(pkcs8PEM: bad))
        }
        let badAlgorithm = tlv(0x30, Data([2, 1, 0]) + tlv(0x30, Data([6, 1, 1])) + tlv(4, Data([0])))
        XCTAssertThrowsError(try PartnerRSAKey(pkcs8PEM: pem(badAlgorithm))) { error in
            XCTAssertEqual(error as? PartnerRSAError, .unsupportedKeyAlgorithm)
        }
    }
    func testRejectsTruncationIndefiniteLengthAndTrailingDER() {
        for der in [Data(), Data([0x30, 0x80, 0, 0]), Data([0x30, 0x82, 1]),
            Data([0x30, 1, 0]), Data([0x30, 0, 0])] {
            XCTAssertThrowsError(try PartnerRSAKey(pkcs8PEM: pem(der)))
        }
    }
    private func pem(_ der: Data) -> String {
        "-----BEGIN \( "PRIVATE KEY" )-----\n" + der.base64EncodedString() + "\n-----END \( "PRIVATE KEY" )-----"
    }
    private func tlv(_ tag: UInt8, _ data: Data) -> Data {
        var length = [UInt8]()
        if data.count < 128 { length = [UInt8(data.count)] }
        else { length = [0x82, UInt8(data.count >> 8), UInt8(data.count & 0xff)] }
        return Data([tag] + length) + data
    }
}
