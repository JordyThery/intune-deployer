import CommonCrypto
import CryptoKit
import Foundation

/// Encrypts app content the way Intune's "ProfileVersion1" expects.
///
/// Layout (verified against two independent production implementations —
/// almenscorner/intune-uploader and simeoncloud/IntuneAppBuilder; the Graph
/// fileEncryptionInfo doc corroborates the field constraints):
///
///     HMAC-SHA256(macKey, IV ‖ ciphertext)  [32 bytes]
///     IV                                     [16 bytes]
///     AES-256-CBC(PKCS7) ciphertext
///
/// fileDigest = SHA-256 of the ORIGINAL file; fileDigestAlgorithm "SHA256";
/// profileIdentifier "ProfileVersion1".
nonisolated enum AppEncryptor {
    struct Result: Sendable {
        /// Full uploaded payload: mac ‖ IV ‖ ciphertext.
        let encrypted: Data
        /// Body for the commit action's fileEncryptionInfo parameter.
        let fileEncryptionInfoJSON: [String: String]
    }

    enum EncryptionError: Error {
        case cryptorFailure(Int32)
        case randomGenerationFailed(OSStatus)
    }

    static func encrypt(_ plaintext: Data) throws -> Result {
        let encryptionKey = try randomBytes(32)
        let macKey = try randomBytes(32)
        let iv = try randomBytes(16)

        let ciphertext = try aes256CBCEncrypt(plaintext, key: encryptionKey, iv: iv)

        var macInput = iv
        macInput.append(ciphertext)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: macKey)))

        var encrypted = mac
        encrypted.append(macInput)

        let digest = Data(SHA256.hash(data: plaintext))

        return Result(
            encrypted: encrypted,
            fileEncryptionInfoJSON: [
                "encryptionKey": encryptionKey.base64EncodedString(),
                "macKey": macKey.base64EncodedString(),
                "initializationVector": iv.base64EncodedString(),
                "mac": mac.base64EncodedString(),
                "profileIdentifier": "ProfileVersion1",
                "fileDigest": digest.base64EncodedString(),
                "fileDigestAlgorithm": "SHA256",
            ]
        )
    }

    /// AES-256-CBC with PKCS7 padding via CommonCrypto (CryptoKit has no CBC).
    static func aes256CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count

        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, plaintext.count,
                            outputBytes.baseAddress, outputCount,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw EncryptionError.cryptorFailure(status)
        }
        return output.prefix(written)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw EncryptionError.randomGenerationFailed(status)
        }
        return data
    }
}
