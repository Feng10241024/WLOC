import Foundation

struct CertificateService: Sendable {
    let validationURL: URL?
    var session: URLSession = .shared

    func validate() async -> CertificateValidationStatus {
        guard let validationURL else {
            return .serviceUnavailable("尚未配置证书验证地址")
        }

        var request = URLRequest(url: validationURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .serviceUnavailable("验证服务未返回 HTTP 响应")
            }
            guard (200...399).contains(httpResponse.statusCode) else {
                return .serviceUnavailable("HTTP \(httpResponse.statusCode)")
            }
            return .valid
        } catch {
            return Self.classify(error)
        }
    }

    static func classify(_ error: Error) -> CertificateValidationStatus {
        let urlError = error as? URLError
            ?? (error as NSError).userInfo[NSUnderlyingErrorKey] as? URLError
        guard let urlError else {
            return .networkFailure(error.localizedDescription)
        }

        switch urlError.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .serverCertificateHasBadDate:
            return .untrusted
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return .networkFailure(urlError.localizedDescription)
        case .badServerResponse, .resourceUnavailable:
            return .serviceUnavailable(urlError.localizedDescription)
        default:
            return .networkFailure(urlError.localizedDescription)
        }
    }
}
