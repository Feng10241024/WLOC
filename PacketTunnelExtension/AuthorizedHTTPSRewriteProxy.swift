import Darwin
import Foundation
import Security

private let authorizedTLSRead: SSLReadFunc = {
    connection, data, dataLength in
    let socket = Unmanaged<AuthorizedTLSSocket>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    while true {
        let received = Darwin.recv(
            socket.fileDescriptor,
            data,
            dataLength.pointee,
            0
        )
        if received > 0 {
            dataLength.pointee = received
            return errSecSuccess
        }
        dataLength.pointee = 0
        if received == 0 {
            return errSSLClosedGraceful
        }
        if errno == EINTR {
            continue
        }
        return errno == EAGAIN || errno == EWOULDBLOCK
            ? errSSLWouldBlock
            : errSecIO
    }
}

private let authorizedTLSWrite: SSLWriteFunc = {
    connection, data, dataLength in
    let socket = Unmanaged<AuthorizedTLSSocket>
        .fromOpaque(UnsafeMutableRawPointer(mutating: connection))
        .takeUnretainedValue()
    while true {
        let sent = Darwin.send(
            socket.fileDescriptor,
            data,
            dataLength.pointee,
            0
        )
        if sent >= 0 {
            dataLength.pointee = sent
            return sent == 0 ? errSSLWouldBlock : errSecSuccess
        }
        dataLength.pointee = 0
        if errno == EINTR {
            continue
        }
        return errno == EAGAIN || errno == EWOULDBLOCK
            ? errSSLWouldBlock
            : errSecIO
    }
}

private final class AuthorizedTLSSocket {
    let fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }
}

private final class AuthorizedUpstreamSessionDelegate:
    NSObject,
    URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A redirect can leave the authorized host or alter the HTTP method.
        // Return the original 3xx response to the client and let it make a new
        // request that must pass through the PAC/allowlist again.
        completionHandler(nil)
    }
}

private struct AuthorizedUpstreamResponse {
    let response: HTTPURLResponse
    let body: Data
}

enum AuthorizedHTTPSRewriteProxyError: Error {
    case listenerCreation
    case listenerConfiguration
    case listenerBind
    case listenerStart
    case connectHeaderTooLarge
    case requestHeaderTooLarge
    case socketRead
    case socketWrite
    case tlsConfiguration(OSStatus)
    case tlsHandshake(OSStatus)
    case tlsRead(OSStatus)
    case tlsWrite(OSStatus)
    case invalidURL
    case rewriteConfigurationUnavailable
    case upstreamTimedOut
    case upstreamFailed
    case invalidUpstreamResponse
}

final class AuthorizedHTTPSRewriteProxy {
    static let defaultPort: UInt16 = 19091

    typealias ConfigurationProvider = () -> SharedLocationConfiguration?

    private let acceptQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.authorized-proxy.accept"
    )
    private let workerQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.authorized-proxy.workers",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let stateQueue = DispatchQueue(
        label: "com.xiaobovlog.WLOC.authorized-proxy.state"
    )
    private let logger = TunnelLogger()
    private var listener: DispatchSourceRead?
    private var listenerFileDescriptor: Int32 = -1
    private var clientFileDescriptors = Set<Int32>()
    private var allowedHosts = Set<String>()
    private var identity: AuthorizedTestTLSIdentity?
    private var configurationProvider: ConfigurationProvider?
    private var metrics = AuthorizedRewriteProxyRuntimeStatus(
        listenerReady: false,
        acceptedConnections: 0,
        rejectedConnections: 0,
        successfulTLSHandshakes: 0,
        rewrittenRequests: 0,
        passThroughRequests: 0,
        failures: 0,
        lastErrorType: nil
    )

    func start(
        identity: AuthorizedTestTLSIdentity,
        allowedHosts: Set<String>,
        port: UInt16 = defaultPort,
        configurationProvider: @escaping ConfigurationProvider
    ) throws {
        stop()
        let safeHosts = Set(
            allowedHosts.compactMap(AuthorizedHostPolicy.validatedHost)
        )
        guard !safeHosts.isEmpty, safeHosts.count == allowedHosts.count else {
            throw AuthorizedHTTPProxyRequestError.hostNotAllowed
        }

        let fileDescriptor = Darwin.socket(
            AF_INET,
            SOCK_STREAM,
            IPPROTO_TCP
        )
        guard fileDescriptor >= 0 else {
            throw AuthorizedHTTPSRewriteProxyError.listenerCreation
        }
        do {
            try configureListener(fileDescriptor, port: port)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }

        stateQueue.sync {
            self.allowedHosts = safeHosts
            self.identity = identity
            self.configurationProvider = configurationProvider
            listenerFileDescriptor = fileDescriptor
            metrics = AuthorizedRewriteProxyRuntimeStatus(
                listenerReady: true,
                acceptedConnections: 0,
                rejectedConnections: 0,
                successfulTLSHandshakes: 0,
                rewrittenRequests: 0,
                passThroughRequests: 0,
                failures: 0,
                lastErrorType: nil
            )
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: acceptQueue
        )
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        stateQueue.sync {
            listener = source
        }
        source.resume()
    }

    func stop() {
        let resources = stateQueue.sync {
            let source = listener
            let listenerFD = listenerFileDescriptor
            listener = nil
            listenerFileDescriptor = -1
            let clients = clientFileDescriptors
            clientFileDescriptors.removeAll()
            identity = nil
            configurationProvider = nil
            allowedHosts.removeAll()
            metrics = AuthorizedRewriteProxyRuntimeStatus(
                listenerReady: false,
                acceptedConnections: metrics.acceptedConnections,
                rejectedConnections: metrics.rejectedConnections,
                successfulTLSHandshakes: metrics.successfulTLSHandshakes,
                rewrittenRequests: metrics.rewrittenRequests,
                passThroughRequests: metrics.passThroughRequests,
                failures: metrics.failures,
                lastErrorType: metrics.lastErrorType
            )
            return (source, clients, listenerFD)
        }
        resources.0?.cancel()
        if resources.2 >= 0 {
            Darwin.close(resources.2)
        }
        for fileDescriptor in resources.1 {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        }
    }

    func snapshot() -> AuthorizedRewriteProxyRuntimeStatus {
        stateQueue.sync { metrics }
    }

    private func configureListener(
        _ fileDescriptor: Int32,
        port: UInt16
    ) throws {
        var reuse: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw AuthorizedHTTPSRewriteProxyError.listenerConfiguration
        }
        var noSignal: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else {
            throw AuthorizedHTTPSRewriteProxyError.listenerConfiguration
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw AuthorizedHTTPSRewriteProxyError.listenerBind
        }
        guard Darwin.listen(fileDescriptor, 32) == 0 else {
            throw AuthorizedHTTPSRewriteProxyError.listenerStart
        }
    }

    private func acceptPendingConnections() {
        while true {
            let listenerFD = stateQueue.sync { listenerFileDescriptor }
            guard listenerFD >= 0 else {
                return
            }
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            configureClient(clientFD)
            stateQueue.sync {
                clientFileDescriptors.insert(clientFD)
                metrics = metrics.updating(
                    acceptedConnections: metrics.acceptedConnections + 1
                )
            }
            workerQueue.async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func configureClient(_ fileDescriptor: Int32) {
        // accept(2) may inherit O_NONBLOCK from the listener on Darwin. The
        // Secure Transport callbacks below use blocking socket semantics, so
        // make that contract explicit for every accepted connection.
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(
                fileDescriptor,
                F_SETFL,
                flags & ~O_NONBLOCK
            )
        }
        var noSignal: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private func handleClient(_ fileDescriptor: Int32) {
        defer {
            _ = stateQueue.sync {
                clientFileDescriptors.remove(fileDescriptor)
            }
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
        }
        do {
            let current = stateQueue.sync {
                (allowedHosts, identity, configurationProvider)
            }
            guard let identity = current.1,
                  let configurationProvider = current.2
            else {
                throw AuthorizedHTTPSRewriteProxyError
                    .rewriteConfigurationUnavailable
            }

            let connectHeader = try readPlainHeader(
                from: fileDescriptor,
                maximumBytes: 16 * 1_024
            )
            let connect = try AuthorizedHTTPConnectRequest.parse(
                headerData: connectHeader,
                allowedHosts: current.0
            )
            try writePlain(
                Data(
                    "HTTP/1.1 200 Connection Established\r\n\r\n".utf8
                ),
                to: fileDescriptor
            )

            let tls = try makeTLSContext(
                fileDescriptor: fileDescriptor,
                identity: identity
            )
            defer {
                SSLClose(tls.context)
            }
            try performHandshake(tls.context)
            updateMetrics {
                $0.updating(
                    successfulTLSHandshakes:
                        $0.successfulTLSHandshakes + 1
                )
            }

            let headerData = try readTLSHeader(
                from: tls.context,
                maximumBytes: 64 * 1_024
            )
            let requestHead = try AuthorizedHTTPRequestHead.parse(
                headerData: headerData,
                connectedHost: connect.host,
                allowedHosts: current.0,
                maximumBodyBytes: 8 * 1_024 * 1_024
            )
            let body = try readTLSBody(
                from: tls.context,
                length: requestHead.contentLength
            )
            guard let originalURL = requestHead.url(for: connect.host),
                  originalURL.host?.lowercased() == connect.host
            else {
                throw AuthorizedHTTPSRewriteProxyError.invalidURL
            }

            if originalURL.path
                == "/.well-known/wloc-certificate-check" {
                try writeTLS(
                    Data(
                        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .utf8
                    ),
                    to: tls.context
                )
                updateMetrics {
                    $0.updating(
                        passThroughRequests: $0.passThroughRequests + 1
                    )
                }
                return
            }
            guard let location = configurationProvider(),
                  location.isValid,
                  location.rewriteEnabled
            else {
                throw AuthorizedHTTPSRewriteProxyError
                    .rewriteConfigurationUnavailable
            }
            let upstream = try performUpstreamRequest(
                requestHead: requestHead,
                url: originalURL,
                body: body
            )
            let wlocRewrite = WLOCProtobufResponseRewriter(
                allowedHosts: current.0
            ).rewrite(
                data: upstream.body,
                response: upstream.response,
                requestURL: originalURL,
                location: location
            )
            if wlocRewrite.matched {
                logger.wlocResponseMatched(
                    host: connect.host,
                    path: originalURL.path,
                    location: location,
                    statistics: wlocRewrite.statistics
                )
                updateMetrics {
                    $0.updating(
                        rewrittenRequests: $0.rewrittenRequests + 1
                    )
                }
            }
            if !wlocRewrite.matched {
                // Authorized hosts may be TLS-terminated, but unmatched
                // requests and responses are returned without body logging.
                updateMetrics {
                    $0.updating(
                        passThroughRequests: $0.passThroughRequests + 1
                    )
                }
            }

            let response = serializeUpstreamResponse(
                upstream.response,
                body: wlocRewrite.data,
                bodyWasRewritten: wlocRewrite.matched,
                preserveContentEncoding:
                    wlocRewrite.preservesContentEncoding
            )
            try writeTLS(response, to: tls.context)
        } catch {
            let type = sanitizedErrorType(error)
            logger.error(type: type)
            updateMetrics {
                let rejected = error is AuthorizedHTTPProxyRequestError
                    ? $0.rejectedConnections + 1
                    : $0.rejectedConnections
                return $0.updating(
                    rejectedConnections: rejected,
                    failures: $0.failures + 1,
                    lastErrorType: type
                )
            }
        }
    }

    private func readPlainHeader(
        from fileDescriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < maximumBytes {
            let count = Darwin.recv(fileDescriptor, &byte, 1, 0)
            if count == 1 {
                result.append(byte)
                if result.suffix(4) == Data("\r\n\r\n".utf8) {
                    return result
                }
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw AuthorizedHTTPSRewriteProxyError.socketRead
        }
        throw AuthorizedHTTPSRewriteProxyError.connectHeaderTooLarge
    }

    private func writePlain(
        _ data: Data,
        to fileDescriptor: Int32
    ) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { bytes in
                Darwin.send(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset,
                    0
                )
            }
            if sent > 0 {
                offset += sent
            } else if sent < 0, errno == EINTR {
                continue
            } else {
                throw AuthorizedHTTPSRewriteProxyError.socketWrite
            }
        }
    }

    private func makeTLSContext(
        fileDescriptor: Int32,
        identity: AuthorizedTestTLSIdentity
    ) throws -> (context: SSLContext, socket: AuthorizedTLSSocket) {
        guard let context = SSLCreateContext(
            nil,
            .serverSide,
            .streamType
        ) else {
            throw AuthorizedHTTPSRewriteProxyError
                .tlsConfiguration(errSecAllocate)
        }
        let socket = AuthorizedTLSSocket(fileDescriptor: fileDescriptor)
        var status = SSLSetIOFuncs(
            context,
            authorizedTLSRead,
            authorizedTLSWrite
        )
        guard status == errSecSuccess else {
            throw AuthorizedHTTPSRewriteProxyError.tlsConfiguration(status)
        }
        status = SSLSetConnection(
            context,
            Unmanaged.passUnretained(socket).toOpaque()
        )
        guard status == errSecSuccess else {
            throw AuthorizedHTTPSRewriteProxyError.tlsConfiguration(status)
        }
        status = SSLSetCertificate(
            context,
            [
                identity.identity,
                identity.rootCertificate
            ] as CFArray
        )
        guard status == errSecSuccess else {
            throw AuthorizedHTTPSRewriteProxyError.tlsConfiguration(status)
        }
        status = SSLSetProtocolVersionMin(context, .tlsProtocol12)
        guard status == errSecSuccess else {
            throw AuthorizedHTTPSRewriteProxyError.tlsConfiguration(status)
        }
        status = SSLSetProtocolVersionMax(context, .tlsProtocol12)
        guard status == errSecSuccess else {
            throw AuthorizedHTTPSRewriteProxyError.tlsConfiguration(status)
        }
        status = SSLSetALPNProtocols(
            context,
            ["http/1.1"] as CFArray
        )
        guard status == errSecSuccess else {
            throw AuthorizedHTTPSRewriteProxyError.tlsConfiguration(status)
        }
        return (context, socket)
    }

    private func performHandshake(_ context: SSLContext) throws {
        let deadline = Date().addingTimeInterval(20)
        while true {
            let status = SSLHandshake(context)
            if status == errSecSuccess {
                return
            }
            if status == errSSLWouldBlock,
               Date() < deadline {
                // Secure Transport explicitly requires SSLHandshake to be
                // called repeatedly for this non-fatal incomplete state.
                continue
            }
            throw AuthorizedHTTPSRewriteProxyError.tlsHandshake(status)
        }
    }

    private func readTLSHeader(
        from context: SSLContext,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        while result.count < maximumBytes {
            var byte: UInt8 = 0
            var processed = 0
            let status = SSLRead(context, &byte, 1, &processed)
            if processed == 1 {
                result.append(byte)
                if result.suffix(4) == Data("\r\n\r\n".utf8) {
                    return result
                }
            }
            if processed > 0 || status == errSecSuccess {
                continue
            }
            throw AuthorizedHTTPSRewriteProxyError.tlsRead(status)
        }
        throw AuthorizedHTTPSRewriteProxyError.requestHeaderTooLarge
    }

    private func readTLSBody(
        from context: SSLContext,
        length: Int
    ) throws -> Data {
        guard length > 0 else {
            return Data()
        }
        var result = Data(count: length)
        var offset = 0
        while offset < length {
            var processed = 0
            let status = result.withUnsafeMutableBytes { bytes in
                SSLRead(
                    context,
                    bytes.baseAddress!.advanced(by: offset),
                    length - offset,
                    &processed
                )
            }
            offset += processed
            if processed > 0 || status == errSecSuccess {
                continue
            }
            throw AuthorizedHTTPSRewriteProxyError.tlsRead(status)
        }
        return result
    }

    private func writeTLS(
        _ data: Data,
        to context: SSLContext
    ) throws {
        var offset = 0
        while offset < data.count {
            var processed = 0
            let status = data.withUnsafeBytes { bytes in
                SSLWrite(
                    context,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset,
                    &processed
                )
            }
            offset += processed
            if processed > 0 || status == errSecSuccess {
                continue
            }
            throw AuthorizedHTTPSRewriteProxyError.tlsWrite(status)
        }
    }

    private func performUpstreamRequest(
        requestHead: AuthorizedHTTPRequestHead,
        url: URL,
        body: Data
    ) throws -> AuthorizedUpstreamResponse {
        var request = URLRequest(url: url)
        request.httpMethod = requestHead.method
        request.httpBody = body.isEmpty ? nil : body
        let excludedHeaders = Set([
            "connection",
            "proxy-connection",
            "keep-alive",
            "transfer-encoding",
            "te",
            "trailer",
            "upgrade",
            "proxy-authorization",
            "content-length",
            "host"
        ])
        for header in requestHead.headers
            where !excludedHeaders.contains(header.name.lowercased()) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("close", forHTTPHeaderField: "Connection")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "kCFNetworkProxiesHTTPEnable": 0,
            "kCFNetworkProxiesHTTPSEnable": 0
        ]
        let session = URLSession(
            configuration: configuration,
            delegate: AuthorizedUpstreamSessionDelegate(),
            delegateQueue: nil
        )
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var receivedData: Data?
        var receivedResponse: URLResponse?
        var receivedError: Error?
        let task = session.dataTask(with: request) {
            data, response, error in
            lock.lock()
            receivedData = data
            receivedResponse = response
            receivedError = error
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 46) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw AuthorizedHTTPSRewriteProxyError.upstreamTimedOut
        }
        session.finishTasksAndInvalidate()
        lock.lock()
        let data = receivedData
        let response = receivedResponse
        let error = receivedError
        lock.unlock()
        if error != nil {
            throw AuthorizedHTTPSRewriteProxyError.upstreamFailed
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthorizedHTTPSRewriteProxyError.invalidUpstreamResponse
        }
        return AuthorizedUpstreamResponse(
            response: httpResponse,
            body: data ?? Data()
        )
    }

    private func serializeUpstreamResponse(
        _ httpResponse: HTTPURLResponse,
        body responseBody: Data,
        bodyWasRewritten: Bool,
        preserveContentEncoding: Bool
    ) -> Data {
        var head = "HTTP/1.1 \(httpResponse.statusCode) \(reasonPhrase(httpResponse.statusCode))\r\n"
        var excludedResponseHeaders = Set([
            "connection",
            "proxy-connection",
            "keep-alive",
            "transfer-encoding",
            "content-length",
            "upgrade"
        ])
        if !preserveContentEncoding {
            excludedResponseHeaders.insert("content-encoding")
        }
        if bodyWasRewritten {
            excludedResponseHeaders.formUnion([
                "content-md5",
                "digest",
                "etag"
            ])
        }
        for (nameValue, valueValue) in httpResponse.allHeaderFields {
            let name = String(describing: nameValue)
            let value = String(describing: valueValue)
            guard !excludedResponseHeaders.contains(name.lowercased()),
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n")
            else {
                continue
            }
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(responseBody.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var result = Data(head.utf8)
        result.append(responseBody)
        return result
    }

    private func reasonPhrase(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Response"
        }
    }

    private func sanitizedErrorType(_ error: Error) -> String {
        if let proxyError = error as? AuthorizedHTTPSRewriteProxyError {
            switch proxyError {
            case .listenerCreation: "listenerCreation"
            case .listenerConfiguration: "listenerConfiguration"
            case .listenerBind: "listenerBind"
            case .listenerStart: "listenerStart"
            case .connectHeaderTooLarge: "connectHeaderTooLarge"
            case .requestHeaderTooLarge: "requestHeaderTooLarge"
            case .socketRead: "socketRead"
            case .socketWrite: "socketWrite"
            case let .tlsConfiguration(status):
                "tlsConfiguration(\(status))"
            case let .tlsHandshake(status):
                "tlsHandshake(\(status))"
            case let .tlsRead(status): "tlsRead(\(status))"
            case let .tlsWrite(status): "tlsWrite(\(status))"
            case .invalidURL: "invalidURL"
            case .rewriteConfigurationUnavailable:
                "rewriteConfigurationUnavailable"
            case .upstreamTimedOut: "upstreamTimedOut"
            case .upstreamFailed: "upstreamFailed"
            case .invalidUpstreamResponse: "invalidUpstreamResponse"
            }
        } else if let requestError =
                    error as? AuthorizedHTTPProxyRequestError {
            switch requestError {
            case .malformedRequest: "malformedRequest"
            case .hostNotAllowed: "hostNotAllowed"
            case .unsupportedPort: "unsupportedPort"
            case .unsupportedTransferEncoding:
                "unsupportedTransferEncoding"
            case .bodyTooLarge: "bodyTooLarge"
            }
        } else {
            "unknown"
        }
    }

    private func updateMetrics(
        _ update: (AuthorizedRewriteProxyRuntimeStatus)
            -> AuthorizedRewriteProxyRuntimeStatus
    ) {
        stateQueue.sync {
            metrics = update(metrics)
        }
    }
}

private extension AuthorizedRewriteProxyRuntimeStatus {
    func updating(
        listenerReady: Bool? = nil,
        acceptedConnections: UInt64? = nil,
        rejectedConnections: UInt64? = nil,
        successfulTLSHandshakes: UInt64? = nil,
        rewrittenRequests: UInt64? = nil,
        passThroughRequests: UInt64? = nil,
        failures: UInt64? = nil,
        lastErrorType: String? = nil
    ) -> AuthorizedRewriteProxyRuntimeStatus {
        AuthorizedRewriteProxyRuntimeStatus(
            listenerReady: listenerReady ?? self.listenerReady,
            acceptedConnections:
                acceptedConnections ?? self.acceptedConnections,
            rejectedConnections:
                rejectedConnections ?? self.rejectedConnections,
            successfulTLSHandshakes:
                successfulTLSHandshakes ?? self.successfulTLSHandshakes,
            rewrittenRequests:
                rewrittenRequests ?? self.rewrittenRequests,
            passThroughRequests:
                passThroughRequests ?? self.passThroughRequests,
            failures: failures ?? self.failures,
            lastErrorType: lastErrorType ?? self.lastErrorType
        )
    }
}
