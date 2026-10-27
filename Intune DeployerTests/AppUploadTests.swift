import CommonCrypto
import CryptoKit
import Foundation
import Testing
@testable import Intune_Deployer

/// Test-side AES-256-CBC decryption to validate the encryptor's output.
private func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
    var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
    var written = 0
    let outputCount = output.count
    let status = output.withUnsafeMutableBytes { outputBytes in
        ciphertext.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                        inputBytes.baseAddress, ciphertext.count,
                        outputBytes.baseAddress, outputCount, &written
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { throw AppEncryptor.EncryptionError.cryptorFailure(status) }
    return output.prefix(written)
}

@Suite("App encryption (ProfileVersion1)")
struct AppEncryptorTests {
    @Test func encryptedLayoutRoundTripsAndMatchesFields() throws {
        let plaintext = Data("This is a fake pkg payload with some length to cross a block boundary.".utf8)
        let result = try AppEncryptor.encrypt(plaintext)
        let info = result.fileEncryptionInfoJSON

        let mac = try #require(Data(base64Encoded: info["mac"]!))
        let iv = try #require(Data(base64Encoded: info["initializationVector"]!))
        let key = try #require(Data(base64Encoded: info["encryptionKey"]!))
        let macKey = try #require(Data(base64Encoded: info["macKey"]!))

        // Field sizes per the fileEncryptionInfo doc.
        #expect(mac.count == 32)
        #expect(iv.count == 16)
        #expect(key.count == 32)
        #expect(macKey.count == 32)
        #expect(info["profileIdentifier"] == "ProfileVersion1")
        #expect(info["fileDigestAlgorithm"] == "SHA256")

        // Layout: mac ‖ IV ‖ ciphertext.
        let payload = result.encrypted
        #expect(payload.prefix(32) == mac)
        #expect(payload.subdata(in: 32..<48) == iv)
        let ciphertext = payload.subdata(in: 48..<payload.count)

        // mac must be HMAC-SHA256(macKey, IV ‖ ciphertext).
        var macInput = iv
        macInput.append(ciphertext)
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: macKey)))
        #expect(expectedMac == mac)

        // Ciphertext decrypts back to the original.
        let decrypted = try aes256CBCDecrypt(ciphertext, key: key, iv: iv)
        #expect(decrypted == plaintext)

        // fileDigest is the SHA-256 of the ORIGINAL file.
        #expect(Data(base64Encoded: info["fileDigest"]!) == Data(SHA256.hash(data: plaintext)))

        // sizeEncrypted bookkeeping: ciphertext is padded to a block multiple.
        #expect(ciphertext.count % 16 == 0)
        #expect(ciphertext.count > plaintext.count - 16)
    }
}

@Suite("Package metadata parsing")
struct AppPackageInspectorTests {
    @Test func parsesProductArchiveDistribution() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="1">
            <title>Demo App</title>
            <product id="com.example.demo" version="2.3.1"/>
            <pkg-ref id="com.example.demo.pkg" version="2.3.1" installKBytes="12345"/>
            <pkg-ref id="com.example.demo.pkg">
                <bundle-version>
                    <bundle CFBundleShortVersionString="2.3.1" id="com.example.demo.app" path="Demo.app"/>
                </bundle-version>
            </pkg-ref>
        </installer-gui-script>
        """.utf8)
        let info = try AppPackageInspector.parseDistribution(xml)
        #expect(info.primaryBundleID == "com.example.demo")
        #expect(info.primaryBundleVersion == "2.3.1")
        #expect(info.includedApps == [AppPackageInfo.IncludedApp(bundleID: "com.example.demo.app", bundleVersion: "2.3.1")])
    }

    @Test func distributionWithoutProductFallsBackToBundles() throws {
        let xml = Data("""
        <installer-gui-script minSpecVersion="1">
            <pkg-ref id="com.vendor.tool" version="7.0"/>
            <pkg-ref id="com.vendor.tool">
                <bundle-version>
                    <bundle CFBundleShortVersionString="7.0" id="com.vendor.tool.app" path="Applications/Tool.app"/>
                </bundle-version>
            </pkg-ref>
        </installer-gui-script>
        """.utf8)
        let info = try AppPackageInspector.parseDistribution(xml)
        #expect(info.primaryBundleID == "com.vendor.tool.app")
        #expect(info.primaryBundleVersion == "7.0")
    }

    @Test func parsesComponentPackageInfo() throws {
        let xml = Data("""
        <pkg-info format-version="2" identifier="com.example.component" version="1.4" install-location="/">
            <bundle-version>
                <bundle CFBundleShortVersionString="1.4" id="com.example.component.app" path="Component.app"/>
            </bundle-version>
        </pkg-info>
        """.utf8)
        let info = try AppPackageInspector.parsePackageInfo(xml)
        #expect(info.primaryBundleID == "com.example.component")
        #expect(info.primaryBundleVersion == "1.4")
        #expect(info.includedApps.first?.bundleID == "com.example.component.app")
    }

    @Test func rejectsMetadataWithoutVersions() {
        let xml = Data("<installer-gui-script><title>Empty</title></installer-gui-script>".utf8)
        #expect(throws: AppInspectionError.self) {
            _ = try AppPackageInspector.parseDistribution(xml)
        }
    }
}

@Suite("App payload builder")
struct AppPayloadTests {
    @Test func buildsPkgAppBodyWithBundleInfo() throws {
        let url = URL(filePath: "/tmp/fixture/apps/Demo-2.3.1.pkg")
        let item = InferredItem(
            id: "aabbccdd",
            sourceID: UUID(),
            relativePath: "apps/Demo-2.3.1.pkg",
            fileURL: url,
            type: .app,
            displayName: "Demo-2.3.1",
            detectionReason: "test"
        )
        let appInfo = AppPackageInfo(
            primaryBundleID: "com.example.demo",
            primaryBundleVersion: "2.3.1",
            includedApps: [AppPackageInfo.IncludedApp(bundleID: "com.example.demo.app", bundleVersion: "2.3.1")]
        )
        let built = try PayloadBuilder.build(item: item, fileData: Data(), namingPrefix: "[CONTOSO]", variables: [:], appInfo: appInfo)
        let body = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])

        #expect(built.collection == .apps)
        #expect(body["@odata.type"] as? String == "#microsoft.graph.macOSPkgApp")
        #expect(body["displayName"] as? String == "[CONTOSO] Demo-2.3.1")
        #expect(body["primaryBundleId"] as? String == "com.example.demo")
        #expect(body["primaryBundleVersion"] as? String == "2.3.1")
        #expect(body["fileName"] as? String == "Demo-2.3.1.pkg")
        let included = try #require(body["includedApps"] as? [[String: Any]])
        #expect(included.first?["bundleId"] as? String == "com.example.demo.app")
        let minOS = try #require(body["minimumSupportedOperatingSystem"] as? [String: Any])
        #expect(minOS["v11_0"] as? Bool == true)
        #expect((body["description"] as? String)?.contains("[IntuneDeployer:aabbccdd]") == true)
    }

    @Test func dmgUsesDmgTypeAndMissingInfoFails() {
        let url = URL(filePath: "/tmp/fixture/apps/Tool.dmg")
        let item = InferredItem(
            id: "11223344", sourceID: UUID(), relativePath: "apps/Tool.dmg",
            fileURL: url, type: .app, displayName: "Tool", detectionReason: "test"
        )
        let appInfo = AppPackageInfo(primaryBundleID: "com.x.tool", primaryBundleVersion: "1.0", includedApps: [])
        let built = try? PayloadBuilder.build(item: item, fileData: Data(), namingPrefix: "", variables: [:], appInfo: appInfo)
        let body = built.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        #expect(body?["@odata.type"] as? String == "#microsoft.graph.macOSDmgApp")
        // Empty includedApps falls back to the primary bundle (dmg requires one).
        #expect((body?["includedApps"] as? [[String: Any]])?.count == 1)

        // No bundle info at all → build error (surfaces as plan error).
        #expect(throws: PayloadError.self) {
            _ = try PayloadBuilder.build(item: item, fileData: Data(), namingPrefix: "", variables: [:], appInfo: nil)
        }
    }
}
