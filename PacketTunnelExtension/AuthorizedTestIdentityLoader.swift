import Foundation
import Security

struct AuthorizedTestTLSIdentity {
    let identity: SecIdentity
    let leafCertificate: SecCertificate
    let rootCertificate: SecCertificate
    let manifest: TestCertificateAssetManifest
}

struct AuthorizedTestIdentityLoader {
    func load(
        appGroupIdentifier: String,
        allowedHosts: Set<String>
    ) throws -> AuthorizedTestTLSIdentity {
        let directory = try TestCertificateAssetPaths.directoryURL(
            appGroupIdentifier: appGroupIdentifier
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            TestCertificateAssetManifest.self,
            from: Data(
                contentsOf: directory.appendingPathComponent(
                    TestCertificateAssetPaths.manifestName
                )
            )
        )
        let safeHosts = allowedHosts
            .compactMap(AuthorizedHostPolicy.validatedHost)
            .sorted()
        let rootData = try Data(
            contentsOf: directory.appendingPathComponent(
                TestCertificateAssetPaths.rootCertificateName
            )
        )
        let leafData = try Data(
            contentsOf: directory.appendingPathComponent(
                TestCertificateAssetPaths.leafCertificateName
            )
        )
        let leafKeyData = try Data(
            contentsOf: directory.appendingPathComponent(
                TestCertificateAssetPaths.leafPrivateKeyName
            )
        )

        guard manifest.isValid,
              manifest.allowedHosts == safeHosts,
              manifest.leafNotAfter.timeIntervalSinceNow > 24 * 60 * 60,
              TestCertificateMaterial(
                der: rootData,
                notAfter: manifest.rootNotAfter
              ).sha256Hex == manifest.rootSHA256,
              let rootCertificate = SecCertificateCreateWithData(
                nil,
                rootData as CFData
              ),
              let leafCertificate = SecCertificateCreateWithData(
                nil,
                leafData as CFData
              )
        else {
            throw TestCertificateAssetError.invalidCertificateAssets
        }

        let leafKey = try TestRSAKeyFactory.importPrivateKey(leafKeyData)
        guard let identity = SecIdentityCreate(
            nil,
            leafCertificate,
            leafKey
        ) else {
            throw TestCertificateAssetError.invalidCertificateAssets
        }
        return AuthorizedTestTLSIdentity(
            identity: identity,
            leafCertificate: leafCertificate,
            rootCertificate: rootCertificate,
            manifest: manifest
        )
    }
}
