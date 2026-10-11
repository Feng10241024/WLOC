import Foundation

enum AuthorizedHTTPProxyRequestError: Error, Equatable {
    case malformedRequest
    case hostNotAllowed
    case unsupportedPort
    case unsupportedTransferEncoding
    case bodyTooLarge
}

struct AuthorizedHTTPConnectRequest: Equatable, Sendable {
    let host: String
    let port: UInt16

    static func parse(
        headerData: Data,
        allowedHosts: Set<String>
    ) throws -> AuthorizedHTTPConnectRequest {
        guard let header = String(data: headerData, encoding: .utf8),
              let firstLine = header.components(separatedBy: "\r\n").first
        else {
            throw AuthorizedHTTPProxyRequestError.malformedRequest
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[0].caseInsensitiveCompare("CONNECT") == .orderedSame,
              parts[2].hasPrefix("HTTP/1."),
              let separator = parts[1].lastIndex(of: ":"),
              let port = UInt16(parts[1][parts[1].index(after: separator)...])
        else {
            throw AuthorizedHTTPProxyRequestError.malformedRequest
        }
        let rawHost = String(parts[1][..<separator])
        guard let host = AuthorizedHostPolicy.validatedHost(rawHost),
              allowedHosts.contains(host)
        else {
            throw AuthorizedHTTPProxyRequestError.hostNotAllowed
        }
        guard port == 443 else {
            throw AuthorizedHTTPProxyRequestError.unsupportedPort
        }
        return AuthorizedHTTPConnectRequest(host: host, port: port)
    }
}

struct AuthorizedHTTPRequestHead: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        let name: String
        let value: String
    }

    let method: String
    let target: String
    let version: String
    let headers: [Header]
    let contentLength: Int

    static func parse(
        headerData: Data,
        connectedHost: String,
        allowedHosts: Set<String>,
        maximumBodyBytes: Int
    ) throws -> AuthorizedHTTPRequestHead {
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw AuthorizedHTTPProxyRequestError.malformedRequest
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw AuthorizedHTTPProxyRequestError.malformedRequest
        }
        let requestParts = lines.removeFirst()
            .split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1.")
        else {
            throw AuthorizedHTTPProxyRequestError.malformedRequest
        }

        var headers: [Header] = []
        var hostHeader: String?
        var contentLength = 0
        var sawContentLength = false
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw AuthorizedHTTPProxyRequestError.malformedRequest
            }
            let name = String(line[..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n")
            else {
                throw AuthorizedHTTPProxyRequestError.malformedRequest
            }
            if name.caseInsensitiveCompare("Host") == .orderedSame {
                guard hostHeader == nil else {
                    throw AuthorizedHTTPProxyRequestError.malformedRequest
                }
                hostHeader = normalizedHostHeader(value)
            } else if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                guard !sawContentLength,
                      let length = Int(value),
                      length >= 0
                else {
                    throw AuthorizedHTTPProxyRequestError.malformedRequest
                }
                sawContentLength = true
                contentLength = length
            } else if name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame,
                      value.caseInsensitiveCompare("identity") != .orderedSame {
                throw AuthorizedHTTPProxyRequestError.unsupportedTransferEncoding
            }
            headers.append(Header(name: name, value: value))
        }

        let expectedHost = connectedHost.lowercased()
        guard let hostHeader,
              hostHeader == expectedHost,
              allowedHosts.contains(hostHeader)
        else {
            throw AuthorizedHTTPProxyRequestError.hostNotAllowed
        }
        guard contentLength <= maximumBodyBytes else {
            throw AuthorizedHTTPProxyRequestError.bodyTooLarge
        }
        return AuthorizedHTTPRequestHead(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            version: String(requestParts[2]),
            headers: headers,
            contentLength: contentLength
        )
    }

    func url(for host: String) -> URL? {
        if let absolute = URL(string: target),
           absolute.scheme?.lowercased() == "https",
           absolute.host?.lowercased() == host.lowercased(),
           absolute.port == nil || absolute.port == 443 {
            return absolute
        }
        guard target.hasPrefix("/") else {
            return nil
        }
        return URL(string: "https://\(host)\(target)")
    }

    private static func normalizedHostHeader(_ value: String) -> String? {
        let lowered = value.lowercased()
        if lowered.hasSuffix(":443") {
            return AuthorizedHostPolicy.validatedHost(
                String(lowered.dropLast(4))
            )
        }
        return AuthorizedHostPolicy.validatedHost(lowered)
    }
}
