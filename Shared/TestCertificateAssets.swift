import CryptoKit
import Foundation
import Security

struct TestCertificateAssetManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let generationID: UUID
    let allowedHosts: [String]
    let rootCommonName: String
    let rootNotAfter: Date
    let leafNotAfter: Date
    let rootSHA256: String

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && !allowedHosts.isEmpty
            && Set(allowedHosts).count == allowedHosts.count
            && rootNotAfter > Date()
            && leafNotAfter > Date()
            && rootSHA256.count == 64
    }
}

enum TestCertificateAssetPaths {
    static let directoryName = "WLOCAuthorizedTestCA"
    static let manifestName = "manifest.json"
    static let rootCertificateName = "WLOC-Authorized-Test-Root.cer"
    static let configurationProfileName =
        "WLOC-Authorized-Test-Root.mobileconfig"
    static let leafCertificateName = "leaf-certificate.der"
    static let leafPrivateKeyName = "leaf-private-key.der"

    static func directoryURL(
        appGroupIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw TestCertificateAssetError.appGroupUnavailable
        }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}

enum TestConfigurationProfileFactory {
    static let profileIdentifier =
        "com.xiaobovlog.WLOC.authorized-test-ca-profile"
    static let certificateIdentifier =
        "com.xiaobovlog.WLOC.authorized-test-ca-certificate"

    static func make(rootCertificateDER: Data) throws -> Data {
        guard SecCertificateCreateWithData(
            nil,
            rootCertificateDER as CFData
        ) != nil else {
            throw TestCertificateAssetError.invalidCertificate
        }
        let certificatePayload: [String: Any] = [
            "PayloadCertificateFileName":
                TestCertificateAssetPaths.rootCertificateName,
            "PayloadContent": rootCertificateDER,
            "PayloadDescription":
                "仅供 WLOC 隔离授权测试环境使用的根证书",
            "PayloadDisplayName": "WLOC 授权测试根证书",
            "PayloadIdentifier": certificateIdentifier,
            "PayloadType": "com.apple.security.root",
            "PayloadUUID": "3D7C48D1-0D88-40E6-9DF2-E5B735623A1D",
            "PayloadVersion": 1
        ]
        let profile: [String: Any] = [
            "PayloadContent": [certificatePayload],
            "PayloadDescription":
                "安装 WLOC 专用测试根证书；仅限已授权的隔离测试设备。",
            "PayloadDisplayName": "WLOC 授权测试 CA",
            "PayloadIdentifier": profileIdentifier,
            "PayloadOrganization": "WLOC Authorized Testing",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": "AC4C2743-B08C-41A5-A3AF-A8690EC86294",
            "PayloadVersion": 1
        ]
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: profile,
                format: .xml,
                options: 0
            )
        } catch {
            throw TestCertificateAssetError.encodingFailed
        }
    }

    static func rootCertificateDER(from profileData: Data) -> Data? {
        guard let profile = try? PropertyListSerialization.propertyList(
            from: profileData,
            format: nil
        ) as? [String: Any],
              profile["PayloadType"] as? String == "Configuration",
              profile["PayloadIdentifier"] as? String == profileIdentifier,
              let content = profile["PayloadContent"] as? [[String: Any]],
              let certificate = content.first,
              certificate["PayloadType"] as? String
                == "com.apple.security.root",
              certificate["PayloadIdentifier"] as? String
                == certificateIdentifier,
              let rootData = certificate["PayloadContent"] as? Data
        else {
            return nil
        }
        return rootData
    }
}

enum TestCertificateAssetError: LocalizedError, Equatable {
    case appGroupUnavailable
    case keyGenerationFailed(Int)
    case keyExportFailed
    case keyImportFailed
    case signatureFailed(Int)
    case invalidCertificate
    case invalidCertificateAssets
    case keychainFailure(Int)
    case unsupportedKey
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "无法访问 App Group，不能安全共享本机授权证书"
        case let .keyGenerationFailed(code):
            "生成授权证书密钥失败（\(code)）"
        case .keyExportFailed:
            "无法导出本机授权证书密钥"
        case .keyImportFailed:
            "无法导入本机授权证书密钥"
        case let .signatureFailed(code):
            "签发授权证书失败（\(code)）"
        case .invalidCertificate:
            "生成的授权证书无效"
        case .invalidCertificateAssets:
            "本机授权证书文件缺失、过期或与白名单不匹配"
        case let .keychainFailure(code):
            "访问授权证书 Keychain 失败（\(code)）"
        case .unsupportedKey:
            "当前密钥不支持 RSA SHA-256 证书签名"
        case .encodingFailed:
            "无法编码授权证书"
        }
    }
}

struct TestCertificateMaterial: Sendable {
    let der: Data
    let notAfter: Date

    var certificate: SecCertificate? {
        SecCertificateCreateWithData(nil, der as CFData)
    }

    var sha256Hex: String {
        SHA256.hash(data: der)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum TestRSAKeyFactory {
    static func makePrivateKey(size: Int = 2_048) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: size
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

    static func exportPrivateKey(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else {
            throw TestCertificateAssetError.keyExportFailed
        }
        return data
    }

    static func importPrivateKey(_ data: Data) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2_048
        ]
        guard let key = SecKeyCreateWithData(
            data as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw TestCertificateAssetError.keyImportFailed
        }
        return key
    }
}

enum TestX509CertificateFactory {
    static func makeRoot(
        privateKey: SecKey,
        commonName: String,
        now: Date = Date()
    ) throws -> TestCertificateMaterial {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw TestCertificateAssetError.unsupportedKey
        }
        let notAfter = now.addingTimeInterval(365 * 24 * 60 * 60)
        let name = try distinguishedName(commonName)
        let extensions = DER.sequence([
            extensionValue(
                oid: "2.5.29.19",
                critical: true,
                value: DER.sequence([DER.boolean(true)])
            ),
            extensionValue(
                oid: "2.5.29.15",
                critical: true,
                value: DER.bitString(Data([0x06]), unusedBits: 1)
            )
        ])
        let tbs = try tbsCertificate(
            serial: randomSerial(),
            issuer: name,
            subject: name,
            publicKey: publicKey,
            notBefore: now.addingTimeInterval(-5 * 60),
            notAfter: notAfter,
            extensions: extensions
        )
        return try signedCertificate(
            tbs: tbs,
            signingKey: privateKey,
            notAfter: notAfter
        )
    }

    static func makeLeaf(
        publicKey: SecKey,
        signingKey: SecKey,
        issuerCommonName: String,
        allowedHosts: [String],
        now: Date = Date()
    ) throws -> TestCertificateMaterial {
        guard !allowedHosts.isEmpty else {
            throw TestCertificateAssetError.encodingFailed
        }
        let notAfter = now.addingTimeInterval(30 * 24 * 60 * 60)
        let san = DER.sequence(
            allowedHosts.sorted().map {
                DER.contextPrimitive(tagNumber: 2, Data($0.utf8))
            }
        )
        let extensions = DER.sequence([
            extensionValue(
                oid: "2.5.29.19",
                critical: true,
                value: DER.sequence([])
            ),
            extensionValue(
                oid: "2.5.29.15",
                critical: true,
                value: DER.bitString(Data([0xA0]), unusedBits: 5)
            ),
            extensionValue(
                oid: "2.5.29.37",
                critical: false,
                value: DER.sequence([try DER.objectIdentifier("1.3.6.1.5.5.7.3.1")])
            ),
            extensionValue(
                oid: "2.5.29.17",
                critical: false,
                value: san
            )
        ])
        let tbs = try tbsCertificate(
            serial: randomSerial(),
            issuer: distinguishedName(issuerCommonName),
            subject: distinguishedName("WLOC Authorized Test Proxy"),
            publicKey: publicKey,
            notBefore: now.addingTimeInterval(-5 * 60),
            notAfter: notAfter,
            extensions: extensions
        )
        return try signedCertificate(
            tbs: tbs,
            signingKey: signingKey,
            notAfter: notAfter
        )
    }

    private static func tbsCertificate(
        serial: Data,
        issuer: Data,
        subject: Data,
        publicKey: SecKey,
        notBefore: Date,
        notAfter: Date,
        extensions: Data
    ) throws -> Data {
        let signatureAlgorithm = try rsaSHA256AlgorithmIdentifier()
        let publicKeyInfo = try subjectPublicKeyInfo(publicKey)
        return DER.sequence([
            DER.explicit(tagNumber: 0, DER.integer(Data([0x02]))),
            DER.integer(serial),
            signatureAlgorithm,
            issuer,
            DER.sequence([
                DER.time(notBefore),
                DER.time(notAfter)
            ]),
            subject,
            publicKeyInfo,
            DER.explicit(tagNumber: 3, extensions)
        ])
    }

    private static func signedCertificate(
        tbs: Data,
        signingKey: SecKey,
        notAfter: Date
    ) throws -> TestCertificateMaterial {
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(signingKey, .sign, algorithm) else {
            throw TestCertificateAssetError.unsupportedKey
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingKey,
            algorithm,
            tbs as CFData,
            &error
        ) as Data? else {
            throw TestCertificateAssetError.signatureFailed(
                (error?.takeRetainedValue() as Error? as NSError?)?.code ?? -1
            )
        }
        let der = DER.sequence([
            tbs,
            try rsaSHA256AlgorithmIdentifier(),
            DER.bitString(signature, unusedBits: 0)
        ])
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw TestCertificateAssetError.invalidCertificate
        }
        return TestCertificateMaterial(der: der, notAfter: notAfter)
    }

    private static func subjectPublicKeyInfo(_ publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let rawKey = SecKeyCopyExternalRepresentation(
            publicKey,
            &error
        ) as Data? else {
            throw TestCertificateAssetError.keyExportFailed
        }
        return DER.sequence([
            DER.sequence([
                try DER.objectIdentifier("1.2.840.113549.1.1.1"),
                DER.null()
            ]),
            DER.bitString(rawKey, unusedBits: 0)
        ])
    }

    private static func distinguishedName(_ commonName: String) throws -> Data {
        DER.sequence([
            DER.set([
                DER.sequence([
                    try DER.objectIdentifier("2.5.4.3"),
                    DER.utf8String(commonName)
                ])
            ])
        ])
    }

    private static func rsaSHA256AlgorithmIdentifier() throws -> Data {
        DER.sequence([
            try DER.objectIdentifier("1.2.840.113549.1.1.11"),
            DER.null()
        ])
    }

    private static func extensionValue(
        oid: String,
        critical: Bool,
        value: Data
    ) -> Data {
        var fields = [(try? DER.objectIdentifier(oid)) ?? Data()]
        if critical {
            fields.append(DER.boolean(true))
        }
        fields.append(DER.octetString(value))
        return DER.sequence(fields)
    }

    private static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8.prefix(16))
        }
        bytes[0] &= 0x7F
        if bytes.allSatisfy({ $0 == 0 }) {
            bytes[bytes.count - 1] = 1
        }
        return Data(bytes)
    }
}

private enum DER {
    static func sequence(_ values: [Data]) -> Data {
        item(tag: 0x30, content: values.reduce(into: Data()) { $0.append($1) })
    }

    static func set(_ values: [Data]) -> Data {
        item(tag: 0x31, content: values.reduce(into: Data()) { $0.append($1) })
    }

    static func integer(_ value: Data) -> Data {
        var bytes = Array(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty {
            bytes = [0]
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return item(tag: 0x02, content: Data(bytes))
    }

    static func boolean(_ value: Bool) -> Data {
        item(tag: 0x01, content: Data([value ? 0xFF : 0x00]))
    }

    static func null() -> Data {
        item(tag: 0x05, content: Data())
    }

    static func utf8String(_ value: String) -> Data {
        item(tag: 0x0C, content: Data(value.utf8))
    }

    static func octetString(_ value: Data) -> Data {
        item(tag: 0x04, content: value)
    }

    static func bitString(_ value: Data, unusedBits: UInt8) -> Data {
        var content = Data([unusedBits])
        content.append(value)
        return item(tag: 0x03, content: content)
    }

    static func explicit(tagNumber: UInt8, _ value: Data) -> Data {
        item(tag: 0xA0 | tagNumber, content: value)
    }

    static func contextPrimitive(tagNumber: UInt8, _ value: Data) -> Data {
        item(tag: 0x80 | tagNumber, content: value)
    }

    static func objectIdentifier(_ value: String) throws -> Data {
        let parts = value.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2,
              parts[0] <= 2,
              parts[0] == 2 || parts[1] < 40
        else {
            throw TestCertificateAssetError.encodingFailed
        }
        var encoded = base128(parts[0] * 40 + parts[1])
        for part in parts.dropFirst(2) {
            encoded.append(contentsOf: base128(part))
        }
        return item(tag: 0x06, content: Data(encoded))
    }

    static func time(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        ).year ?? 2000
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if (1950..<2050).contains(year) {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return item(tag: 0x17, content: Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return item(tag: 0x18, content: Data(formatter.string(from: date).utf8))
    }

    private static func item(tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        result.append(length(content.count))
        result.append(content)
        return result
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 {
            return Data([UInt8(count)])
        }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }
}
