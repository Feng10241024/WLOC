import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let configurationSchemaVersion = 13
    private let loader = TunnelConfigurationLoader()
    private let proxyService = AuthorizedProxyService()
    private let rewriteProxy = AuthorizedHTTPSRewriteProxy()
    private let logger = TunnelLogger()
    private let stateQueue = DispatchQueue(label: "com.xiaobovlog.WLOC.tunnel-state")
    private var runtimeConfiguration: TunnelRuntimeConfiguration?
    private var loadedConfigurationVersion = 0
    private var diagnosticStore: TunnelDiagnosticStore?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let providerConfiguration = (
                protocolConfiguration as? NETunnelProviderProtocol
            )?.providerConfiguration
            let appGroupIdentifier =
                providerConfiguration?["appGroupIdentifier"] as? String
                ?? SharedConstants.appGroupIdentifier
            diagnosticStore = TunnelDiagnosticStore(
                suiteName: appGroupIdentifier
            )
            record(.startRequested)
            let configuration = try loader.load(
                providerConfiguration: providerConfiguration
            )
            record(.configurationLoaded)
            let settings: NEPacketTunnelNetworkSettings
            switch configuration.mode {
            case .diagnosticNoTraffic:
                settings = proxyService.makeDiagnosticNetworkSettings()
            case .localForwarding:
                guard let location = configuration.location,
                      location.rewriteEnabled
                else {
                    throw PacketTunnelError.rewriteDisabled
                }
                record(.localProxyStarting)
                let identity = try AuthorizedTestIdentityLoader().load(
                    appGroupIdentifier: appGroupIdentifier,
                    allowedHosts: configuration.allowedHosts
                )
                try rewriteProxy.start(
                    identity: identity,
                    allowedHosts: configuration.allowedHosts
                ) { [weak self] in
                    guard let self else {
                        return location
                    }
                    return self.stateQueue.sync {
                        self.runtimeConfiguration?.location ?? location
                    }
                }
                record(.localProxyReady)
                settings = proxyService.makeLocalForwardingNetworkSettings(
                    allowedHosts: configuration.allowedHosts,
                    proxyPort: AuthorizedHTTPSRewriteProxy.defaultPort
                )
            case .authorizedRemoteProxy:
                guard let location = configuration.location,
                      location.rewriteEnabled
                else {
                    throw PacketTunnelError.rewriteDisabled
                }
                guard let proxyURL = configuration.authorizedProxyURL else {
                    throw TunnelConfigurationError.invalidProxyURL
                }
                settings = try proxyService.makeNetworkSettings(
                    proxyURL: proxyURL,
                    allowedHosts: configuration.allowedHosts
                )
            }

            apply(
                settings: settings,
                configuration: configuration,
                completionHandler: completionHandler
            )
        } catch {
            rewriteProxy.stop()
            record(.startFailed, error: error)
            logger.error(type: String(describing: type(of: error)))
            completionHandler(error)
        }
    }

    private func apply(
        settings: NEPacketTunnelNetworkSettings,
        configuration: TunnelRuntimeConfiguration,
        completionHandler: @escaping (Error?) -> Void
    ) {
        record(.networkSettingsApplying)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(PacketTunnelError.providerReleased)
                return
            }
            if let error {
                self.rewriteProxy.stop()
                self.record(.startFailed, error: error)
                self.logger.error(type: "networkSettings")
                completionHandler(error)
                return
            }
            self.record(.networkSettingsApplied)
            self.finishStart(
                configuration: configuration,
                completionHandler: completionHandler
            )
        }
    }

    private func finishStart(
        configuration: TunnelRuntimeConfiguration,
        completionHandler: @escaping (Error?) -> Void
    ) {
        stateQueue.sync {
            runtimeConfiguration = configuration
            loadedConfigurationVersion =
                configuration.location?.configurationVersion ?? 0
        }
        completionHandler(nil)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stateQueue.sync {
            runtimeConfiguration = nil
            loadedConfigurationVersion = 0
        }
        rewriteProxy.stop()
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let response: TunnelProviderResponse
        do {
            let message = try JSONDecoder().decode(
                TunnelProviderMessage.self,
                from: messageData
            )
            switch message.action {
            case .reloadConfiguration:
                response = try reloadConfiguration(
                    requestedVersion: message.configurationVersion,
                    requestID: message.requestID
                )
            case .queryStatus:
                let current = stateQueue.sync {
                    (loadedConfigurationVersion, runtimeConfiguration)
                }
                let runtimeStatus = makeRuntimeStatus(
                    configuration: current.1
                )
                response = providerResponse(
                    result: .status,
                    loadedConfigurationVersion: current.0,
                    message: runtimeStatusMessage(runtimeStatus),
                    runtimeStatus: runtimeStatus,
                    requestID: message.requestID
                )
            }
        } catch {
            logger.error(type: "providerMessage")
            response = providerResponse(
                result: .failed,
                loadedConfigurationVersion: 0,
                message: "无法处理配置消息",
                requestID: nil
            )
        }
        completionHandler?(try? JSONEncoder().encode(response))
    }

    private func reloadConfiguration(
        requestedVersion: Int,
        requestID: UUID?
    ) throws -> TunnelProviderResponse {
        let providerConfiguration = (
            protocolConfiguration as? NETunnelProviderProtocol
        )?.providerConfiguration
        let reloaded = try loader.load(providerConfiguration: providerConfiguration)
        if reloaded.mode == .diagnosticNoTraffic {
            stateQueue.sync {
                runtimeConfiguration = reloaded
                loadedConfigurationVersion = max(
                    loadedConfigurationVersion,
                    requestedVersion
                )
            }
            return providerResponse(
                result: .configurationLoaded,
                loadedConfigurationVersion: requestedVersion,
                message: "诊断模式未接管任何网络流量",
                requestID: requestID
            )
        }
        guard let reloadedLocation = reloaded.location else {
            throw TunnelConfigurationError.invalidLocation
        }
        let currentVersion = stateQueue.sync {
            loadedConfigurationVersion
        }
        guard ConfigurationVersionPolicy.shouldAccept(
            currentVersion: currentVersion,
            requestedVersion: requestedVersion,
            loadedVersion: reloadedLocation.configurationVersion
        )
        else {
            return providerResponse(
                result: .rejectedStaleConfiguration,
                loadedConfigurationVersion: currentVersion,
                message: nil,
                requestID: requestID
            )
        }
        stateQueue.sync {
            runtimeConfiguration = reloaded
            loadedConfigurationVersion = reloadedLocation.configurationVersion
        }
        return providerResponse(
            result: .configurationLoaded,
            loadedConfigurationVersion: reloadedLocation.configurationVersion,
            message: nil,
            requestID: requestID
        )
    }

    private func providerResponse(
        result: TunnelProviderResponse.Result,
        loadedConfigurationVersion: Int,
        message: String?,
        runtimeStatus: TunnelRuntimeStatus? = nil,
        requestID: UUID?
    ) -> TunnelProviderResponse {
        TunnelProviderResponse(
            result: result,
            loadedConfigurationVersion: loadedConfigurationVersion,
            message: message,
            runtimeStatus: runtimeStatus,
            requestID: requestID,
            providerBundleIdentifier: Bundle.main.bundleIdentifier,
            providerBuildNumber: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            configurationSchemaVersion: Self.configurationSchemaVersion
        )
    }

    private func makeRuntimeStatus(
        configuration: TunnelRuntimeConfiguration?
    ) -> TunnelRuntimeStatus? {
        guard let configuration else {
            return nil
        }
        let snapshot = rewriteProxy.snapshot()
        return TunnelRuntimeStatus(
            mode: configuration.mode,
            engineRunning: configuration.mode == .localForwarding
                ? snapshot.listenerReady
                : true,
            openSourceCore: configuration.mode == .localForwarding
                ? "WLOC Authorized HTTPS Rewrite Proxy"
                : nil,
            lastDirectActivitySeconds: nil,
            localSocksPort: nil,
            transmittedPackets: 0,
            transmittedBytes: 0,
            receivedPackets: 0,
            receivedBytes: 0,
            localProxy: nil,
            rewriteProxy: configuration.mode == .localForwarding
                ? snapshot
                : nil
        )
    }

    private func runtimeStatusMessage(_ status: TunnelRuntimeStatus?) -> String? {
        guard let status else {
            return "Extension 已启动，但运行配置不可用"
        }
        switch status.mode {
        case .diagnosticNoTraffic:
            return "Extension 正常运行（诊断模式）"
        case .localForwarding:
            guard status.engineRunning else {
                return "Extension 已连接，但本机授权 HTTPS 重写代理未运行"
            }
            let metrics = status.rewriteProxy
            var message = "运行中；连接 \(metrics?.acceptedConnections ?? 0)，TLS \(metrics?.successfulTLSHandshakes ?? 0)，已重写 \(metrics?.rewrittenRequests ?? 0)，未匹配直通 \(metrics?.passThroughRequests ?? 0)，失败 \(metrics?.failures ?? 0)"
            if let error = metrics?.lastErrorType {
                message += "，\(error)"
            }
            return message
        case .authorizedRemoteProxy:
            return "Extension 正常运行（授权远端代理模式）"
        }
    }

    private func record(
        _ phase: TunnelStartupPhase,
        error: Error? = nil
    ) {
        diagnosticStore?.save(phase: phase, error: error)
    }
}

enum PacketTunnelError: LocalizedError {
    case rewriteDisabled
    case providerReleased

    var errorDescription: String? {
        switch self {
        case .rewriteDisabled:
            "测试数据重写未开启"
        case .providerReleased:
            "Packet Tunnel Provider 已释放"
        }
    }
}

#if LEGACY_LOCAL_SOCKS
private final class ProviderSocks5UpstreamFactory: LocalSocks5UpstreamFactory {
    private weak var provider: NEPacketTunnelProvider?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func makeTCPUpstream(
        to destination: Socks5Destination,
        callbackQueue: DispatchQueue
    ) -> LocalSocks5TCPUpstream? {
        guard let provider else {
            return nil
        }
        let endpoint = NWHostEndpoint(
            hostname: destination.displayHost,
            port: String(destination.port)
        )
        let connection = provider.createTCPConnection(
            to: endpoint,
            enableTLS: false,
            tlsParameters: nil,
            delegate: nil
        )
        return ProviderDirectTCPUpstream(
            connection: connection,
            callbackQueue: callbackQueue
        )
    }

    func makeUDPUpstream(
        to destination: Socks5Destination,
        callbackQueue: DispatchQueue
    ) -> LocalSocks5UDPUpstream? {
        guard let provider else {
            return nil
        }
        let endpoint = NWHostEndpoint(
            hostname: destination.displayHost,
            port: String(destination.port)
        )
        let session = provider.createUDPSession(
            to: endpoint,
            from: nil
        )
        return ProviderDirectUDPUpstream(
            session: session,
            callbackQueue: callbackQueue
        )
    }
}

private final class ProviderDirectTCPUpstream: LocalSocks5TCPUpstream {
    private let connection: NWTCPConnection
    private let callbackQueue: DispatchQueue
    private var stateObservation: NSKeyValueObservation?
    private var cancelled = false
    private var readyReported = false
    private var failureReported = false
    private var onReady: (() -> Void)?
    private var onFailure: ((Error) -> Void)?

    init(
        connection: NWTCPConnection,
        callbackQueue: DispatchQueue
    ) {
        self.connection = connection
        self.callbackQueue = callbackQueue
    }

    func start(
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onReady = onReady
        self.onFailure = onFailure
        stateObservation = connection.observe(
            \.state,
            options: [.initial, .new]
        ) { [weak self] connection, _ in
            self?.callbackQueue.async { [weak self] in
                self?.handle(connection.state)
            }
        }
        callbackQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  !self.cancelled,
                  !self.readyReported,
                  !self.failureReported
            else {
                return
            }
            self.reportFailure(ProviderDirectConnectionError.timedOut)
        }
    }

    func send(
        _ data: Data?,
        isComplete: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        let finish: (Error?) -> Void = { [weak self] error in
            guard let self else {
                return
            }
            self.callbackQueue.async {
                if error == nil, isComplete {
                    self.connection.writeClose()
                }
                completion(error)
            }
        }
        guard let data, !data.isEmpty else {
            if isComplete {
                connection.writeClose()
            }
            completion(nil)
            return
        }
        connection.write(data, completionHandler: finish)
    }

    func receive(
        minimumLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Error?) -> Void
    ) {
        connection.readMinimumLength(
            minimumLength,
            maximumLength: maximumLength
        ) { [weak self] data, error in
            guard let self else {
                return
            }
            self.callbackQueue.async {
                let isComplete = error == nil
                    && (data == nil || data?.isEmpty == true)
                completion(data, isComplete, error)
            }
        }
    }

    func cancel() {
        cancelled = true
        stateObservation = nil
        connection.cancel()
    }

    private func handle(_ state: NWTCPConnectionState) {
        guard !cancelled else {
            return
        }
        switch state {
        case .connected:
            guard !readyReported else {
                return
            }
            readyReported = true
            onReady?()
        case .invalid, .disconnected:
            reportFailure(
                connection.error
                    ?? ProviderDirectConnectionError.tcpUnavailable
            )
        case .cancelled:
            break
        case .connecting, .waiting:
            break
        @unknown default:
            reportFailure(ProviderDirectConnectionError.tcpUnavailable)
        }
    }

    private func reportFailure(_ error: Error) {
        guard !failureReported, !cancelled else {
            return
        }
        failureReported = true
        onFailure?(error)
    }
}

private final class ProviderDirectUDPUpstream: LocalSocks5UDPUpstream {
    private let session: NWUDPSession
    private let callbackQueue: DispatchQueue
    private var stateObservation: NSKeyValueObservation?
    private var cancelled = false
    private var readyReported = false
    private var failureReported = false
    private var onReady: (() -> Void)?
    private var onFailure: ((Error) -> Void)?

    init(
        session: NWUDPSession,
        callbackQueue: DispatchQueue
    ) {
        self.session = session
        self.callbackQueue = callbackQueue
    }

    func start(
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onReady = onReady
        self.onFailure = onFailure
        stateObservation = session.observe(
            \.state,
            options: [.initial, .new]
        ) { [weak self] session, _ in
            self?.callbackQueue.async { [weak self] in
                self?.handle(session.state)
            }
        }
        callbackQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  !self.cancelled,
                  !self.readyReported,
                  !self.failureReported
            else {
                return
            }
            self.reportFailure(ProviderDirectConnectionError.timedOut)
        }
    }

    func send(
        _ data: Data,
        completion: @escaping (Error?) -> Void
    ) {
        session.writeDatagram(data) { [weak self] error in
            guard let self else {
                return
            }
            self.callbackQueue.async {
                completion(error)
            }
        }
    }

    func receive(
        completion: @escaping ([Data]?, Error?) -> Void
    ) {
        session.setReadHandler(
            { [weak self] datagrams, error in
                guard let self else {
                    return
                }
                self.callbackQueue.async {
                    completion(datagrams, error)
                }
            },
            maxDatagrams: 1
        )
    }

    func cancel() {
        cancelled = true
        stateObservation = nil
        session.cancel()
    }

    private func handle(_ state: NWUDPSessionState) {
        guard !cancelled else {
            return
        }
        switch state {
        case .ready:
            guard !readyReported else {
                return
            }
            readyReported = true
            onReady?()
        case .invalid, .failed:
            reportFailure(ProviderDirectConnectionError.udpUnavailable)
        case .cancelled:
            break
        case .waiting, .preparing:
            break
        @unknown default:
            reportFailure(ProviderDirectConnectionError.udpUnavailable)
        }
    }

    private func reportFailure(_ error: Error) {
        guard !failureReported, !cancelled else {
            return
        }
        failureReported = true
        onFailure?(error)
    }
}

private enum ProviderDirectConnectionError: LocalizedError {
    case tcpUnavailable
    case udpUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .tcpUnavailable:
            "物理网络 TCP 直连不可用"
        case .udpUnavailable:
            "物理网络 UDP 直连不可用"
        case .timedOut:
            "物理网络直连超时"
        }
    }
}
#endif
