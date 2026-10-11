import Foundation
import Security

struct LocalTestCertificateAuthoritySnapshot: Equatable, Sendable {
    let manifest: TestCertificateAssetManifest
    let rootCertificateURL: URL
    let configurationProfileURL: URL

    var fingerprintDisplay: String {
        stride(from: 0, to: manifest.rootSHA256.count, by: 2)
            .map { index -> String in
                let start = manifest.rootSHA256.index(
                    manifest.rootSHA256.startIndex,
                    offsetBy: index
                )
                let end = manifest.rootSHA256.index(
                    start,
                    offsetBy: min(
                        2,
                        manifest.rootSHA256.distance(
                            from: start,
                            to: manifest.rootSHA256.endIndex
                        )
                    )
                )
                return String(manifest.rootSHA256[start..<end]).uppercased()
            }
            .joined(separator: ":")
    }
}

struct LocalTestCertificateAuthorityService: Sendable {
    static let rootCommonName = "WLOC Authorized Test Root"

    let appGroupIdentifier: String
    let allowedHosts: Set<String>

    func prepare() throws -> LocalTestCertificateAuthoritySnapshot {
        let safeHosts = allowedHosts
            .compactMap(AuthorizedHostPolicy.validatedHost)
            .sorted()
        guard !safeHosts.isEmpty, safeHosts.count == allowedHosts.count else {
            throw TestCertificateAssetError.invalidCertificateAssets
        }

        if let existing = try? loadSnapshot(),
           existing.manifest.allowedHosts == safeHosts,
           existing.manifest.rootNotAfter.timeIntervalSinceNow > 30 * 24 * 60 * 60,
           existing.manifest.leafNotAfter.timeIntervalSinceNow > 7 * 24 * 60 * 60 {
            return existing
        }

        let rootKey = try loadOrCreateRootKey()
        let root = try loadOrCreateRootCertificate(privateKey: rootKey)
        let leafKey = try TestRSAKeyFactory.makePrivateKey()
        guard let leafPublicKey = SecKeyCopyPublicKey(leafKey) else {
            throw TestCertificateAssetError.unsupportedKey
        }
        let leaf = try TestX509CertificateFactory.makeLeaf(
            publicKey: leafPublicKey,
            signingKey: rootKey,
            issuerCommonName: Self.rootCommonName,
            allowedHosts: safeHosts
        )
        let leafKeyData = try TestRSAKeyFactory.exportPrivateKey(leafKey)
        let manifest = TestCertificateAssetManifest(
            schemaVersion: TestCertificateAssetManifest.schemaVersion,
            generationID: UUID(),
            allowedHosts: safeHosts,
            rootCommonName: Self.rootCommonName,
            rootNotAfter: root.notAfter,
            leafNotAfter: leaf.notAfter,
            rootSHA256: root.sha256Hex
        )

        let directory = try TestCertificateAssetPaths.directoryURL(
            appGroupIdentifier: appGroupIdentifier
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifestData = try JSONEncoder.wlocCertificateEncoder
            .encode(manifest)
        let configurationProfileData = try TestConfigurationProfileFactory
            .make(rootCertificateDER: root.der)
        try write(
            root.der,
            to: directory.appendingPathComponent(
                TestCertificateAssetPaths.rootCertificateName
            ),
            privateAsset: false
        )
        try write(
            configurationProfileData,
            to: directory.appendingPathComponent(
                TestCertificateAssetPaths.configurationProfileName
            ),
            privateAsset: false
        )
        try write(
            leaf.der,
            to: directory.appendingPathComponent(
                TestCertificateAssetPaths.leafCertificateName
            ),
            privateAsset: false
        )
        try write(
            leafKeyData,
            to: directory.appendingPathComponent(
                TestCertificateAssetPaths.leafPrivateKeyName
            ),
            privateAsset: true
        )
        try write(
            manifestData,
            to: directory.appendingPathComponent(
                TestCertificateAssetPaths.manifestName
            ),
            privateAsset: true
        )
        return try loadSnapshot()
    }

    func loadSnapshot() throws -> LocalTestCertificateAuthoritySnapshot {
        let directory = try TestCertificateAssetPaths.directoryURL(
            appGroupIdentifier: appGroupIdentifier
        )
        let manifestData = try Data(
            contentsOf: directory.appendingPathComponent(
                TestCertificateAssetPaths.manifestName
            )
        )
        let manifest = try JSONDecoder.wlocCertificateDecoder
            .decode(TestCertificateAssetManifest.self, from: manifestData)
        let rootURL = directory.appendingPathComponent(
            TestCertificateAssetPaths.rootCertificateName
        )
        let rootData = try Data(contentsOf: rootURL)
        let configurationProfileURL = directory.appendingPathComponent(
            TestCertificateAssetPaths.configurationProfileName
        )
        let configurationProfileData = try Data(
            contentsOf: configurationProfileURL
        )
        let expectedHosts = allowedHosts
            .compactMap(AuthorizedHostPolicy.validatedHost)
            .sorted()
        guard manifest.isValid,
              manifest.allowedHosts == expectedHosts,
              TestCertificateMaterial(
                der: rootData,
                notAfter: manifest.rootNotAfter
              ).sha256Hex == manifest.rootSHA256,
              TestConfigurationProfileFactory.rootCertificateDER(
                from: configurationProfileData
              ) == rootData,
              SecCertificateCreateWithData(nil, rootData as CFData) != nil
        else {
            throw TestCertificateAssetError.invalidCertificateAssets
        }
        return LocalTestCertificateAuthoritySnapshot(
            manifest: manifest,
            rootCertificateURL: rootURL,
            configurationProfileURL: configurationProfileURL
        )
    }

    var certificateValidationURL: URL? {
        guard let host = allowedHosts.sorted().first else {
            return nil
        }
        return URL(
            string: "https://\(host)/.well-known/wloc-certificate-check"
        )
    }

    private func loadOrCreateRootKey() throws -> SecKey {
        let tag = Data(
            "com.xiaobovlog.WLOC.authorized-test-root-key".utf8
        )
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: tag,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecReturnRef: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item as! SecKey? {
            return key
        }
        guard status == errSecItemNotFound else {
            throw TestCertificateAssetError.keychainFailure(Int(status))
        }

        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: tag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        guard let key = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &error
        ) else {
            throw TestCertificateAssetError.keyGenerationFailed(
                (error?.takeRetainedValue() as Error? as NSError?)?.code ?? -1
            )
        }
        return key
    }

    private func loadOrCreateRootCertificate(
        privateKey: SecKey
    ) throws -> TestCertificateMaterial {
        let service = "com.xiaobovlog.WLOC.authorized-test-ca"
        let account = "root-certificate-der"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let record = try? JSONDecoder.wlocCertificateDecoder.decode(
                RootCertificateRecord.self,
                from: data
           ),
           record.notAfter > Date(),
           SecCertificateCreateWithData(nil, record.der as CFData) != nil {
            return TestCertificateMaterial(
                der: record.der,
                notAfter: record.notAfter
            )
        }
        guard status == errSecItemNotFound || status == errSecSuccess else {
            throw TestCertificateAssetError.keychainFailure(Int(status))
        }

        let root = try TestX509CertificateFactory.makeRoot(
            privateKey: privateKey,
            commonName: Self.rootCommonName
        )
        let recordData = try JSONEncoder.wlocCertificateEncoder.encode(
            RootCertificateRecord(
                der: root.der,
                notAfter: root.notAfter
            )
        )
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: recordData
        ]
        SecItemDelete(query as CFDictionary)
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TestCertificateAssetError.keychainFailure(Int(addStatus))
        }
        return root
    }

    private func write(
        _ data: Data,
        to url: URL,
        privateAsset: Bool
    ) throws {
        try data.write(to: url, options: [.atomic])
        var attributes: [FileAttributeKey: Any] = [
            .protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication
        ]
        if privateAsset {
            attributes[.posixPermissions] = 0o600
        }
        try FileManager.default.setAttributes(
            attributes,
            ofItemAtPath: url.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }
}

private struct RootCertificateRecord: Codable {
    let der: Data
    let notAfter: Date
}

private extension JSONEncoder {
    static var wlocCertificateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var wlocCertificateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
