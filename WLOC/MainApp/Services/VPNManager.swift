import Combine
import Foundation
import NetworkExtension

@MainActor
final class VPNManager: ObservableObject, TunnelConfigurationNotifying {
    private static let configurationSchemaVersion = 13

    @Published private(set) var status: VPNConnectionStatus = .notConfigured
    @Published private(set) var isConfigured = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastProviderDiagnostic: TunnelDiagnosticSnapshot?
    @Published private(set) var unexpectedDisconnectSequence = 0
    @Published private(set) var providerIdentityVerified = false
    @Published private(set) var providerBuildNumber: String?
    @Published private(set) var providerRuntimeStatus: TunnelRuntimeStatus?

    private let configuration: AppConfiguration
    private let diagnosticStore: TunnelDiagnosticStore?
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var userRequestedStop = false

    var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "未知"
    }

    var hasSuccessfulConnection: Bool {
        ConnectionSuccessPolicy.isSatisfied(
            vpnStatus: status,
            providerIdentityVerified: providerIdentityVerified,
            runtimeStatus: providerRuntimeStatus
        )
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        diagnosticStore = TunnelDiagnosticStore(
            suiteName: configuration.appGroupIdentifier
        )
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      let managedConnection = self.manager?.connection,
                      connection === managedConnection
                else {
                    return
                }
                await self.handleStatusChange(connection)
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func loadConfiguration() async {
        do {
            let managers = try await loadManagers()
            manager = managers.first(where: { candidate in
                (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == configuration.tunnelProviderBundleIdentifier
            })
            if let manager {
                isConfigured = true
                apply(manager.connection.status)
            } else {
                isConfigured = false
                status = .notConfigured
            }
            lastError = nil
            await refreshProviderDiagnostics()
            if manager?.connection.status == .connected {
                await verifyConnectedProvider()
            }
        } catch {
            manager = nil
            isConfigured = false
            status = .failed
            lastError = configurationErrorMessage(
                prefix: "读取网络配置失败",
                error: error
            )
        }
    }

    func installConfigurationIfNeeded() async throws {
        let activeManager = manager ?? NETunnelProviderManager()
        let tunnelProtocol = (
            activeManager.protocolConfiguration as? NETunnelProviderProtocol
        ) ?? NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = configuration.tunnelProviderBundleIdentifier
        tunnelProtocol.serverAddress = switch configuration.tunnelMode {
        case .diagnosticNoTraffic:
            "127.0.0.1"
        case .localForwarding:
            "127.0.0.1"
        case .authorizedRemoteProxy:
            configuration.authorizedProxyURL?.host ?? "授权测试代理（未配置）"
        }
        var providerConfiguration: [String: Any] = [
            "appGroupIdentifier": configuration.appGroupIdentifier,
            "allowedHosts": Array(configuration.allowedHosts).sorted(),
            "authorizedProxyURL": configuration.authorizedProxyURL?.absoluteString ?? "",
            "tunnelMode": configuration.tunnelMode.rawValue,
            "configurationSchemaVersion": Self.configurationSchemaVersion,
            "appBuildNumber": appBuildNumber
        ]
        let persistence = SettingsPersistenceService(
            appGroupIdentifier: configuration.appGroupIdentifier
        )
        if let shared = persistence.sharedConfiguration() {
            providerConfiguration["embeddedMockLongitude"] = shared.longitude
            providerConfiguration["embeddedMockLatitude"] = shared.latitude
            providerConfiguration["embeddedMockAccuracy"] = shared.accuracy
            providerConfiguration["embeddedRewriteEnabled"] = shared.rewriteEnabled
            providerConfiguration["embeddedConfigurationVersion"] =
                shared.configurationVersion
        }
        tunnelProtocol.providerConfiguration = providerConfiguration
        activeManager.protocolConfiguration = tunnelProtocol
        activeManager.localizedDescription = "WLOC 授权测试数据重写"
        activeManager.isEnabled = true

        do {
            try await save(activeManager)
            try await reload(activeManager)
            manager = activeManager
            isConfigured = true
            apply(activeManager.connection.status)
            lastError = nil
            lastProviderDiagnostic = diagnosticStore?.load()
        } catch {
            let mappedError = userFacingConfigurationError(error)
            manager = nil
            isConfigured = false
            await loadConfiguration()
            if !isConfigured {
                status = .failed
            }
            lastError = mappedError.localizedDescription
            throw mappedError
        }
    }

    func start() async throws {
        guard let manager else {
            throw VPNManagerError.notConfigured
        }
        guard configuration.tunnelMode == .diagnosticNoTraffic
                || configuration.tunnelMode == .localForwarding
                || configuration.authorizedProxyURL != nil
        else {
            throw VPNManagerError.proxyEndpointMissing
        }
        do {
            userRequestedStop = false
            lastProviderDiagnostic = nil
            resetProviderIdentity()
            try manager.connection.startVPNTunnel()
            status = .connecting
            lastError = nil
        } catch {
            status = .failed
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        userRequestedStop = true
        resetProviderIdentity()
        guard let manager else {
            isConfigured = false
            status = .notConfigured
            return
        }
        switch manager.connection.status {
        case .connecting, .connected, .reasserting:
            manager.connection.stopVPNTunnel()
            status = .disconnecting
        case .disconnecting:
            status = .disconnecting
        case .invalid, .disconnected:
            apply(manager.connection.status)
        @unknown default:
            status = .failed
        }
    }

    func removeConfiguration() async throws {
        userRequestedStop = true
        guard let manager else {
            isConfigured = false
            status = .notConfigured
            lastError = nil
            return
        }
        if manager.connection.status == .connecting
            || manager.connection.status == .connected
            || manager.connection.status == .reasserting {
            manager.connection.stopVPNTunnel()
        }

        do {
            try await remove(manager)
            self.manager = nil
            isConfigured = false
            status = .notConfigured
            lastError = nil
            resetProviderIdentity()
        } catch {
            let mappedError = userFacingConfigurationError(error)
            self.manager = nil
            isConfigured = false
            await loadConfiguration()
            if !isConfigured {
                status = .failed
            }
            lastError = mappedError.localizedDescription
            throw mappedError
        }
    }

    func notifyConfigurationChanged(version: Int) async -> TunnelProviderResponse? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected
        else {
            return nil
        }
        let message = TunnelProviderMessage(
            action: .reloadConfiguration,
            configurationVersion: version,
            requestID: UUID()
        )
        do {
            let data = try JSONEncoder().encode(message)
            let responseData = try await send(data, through: session)
            guard let responseData else {
                return TunnelProviderResponse(
                    result: .failed,
                    loadedConfigurationVersion: version,
                    message: "扩展未返回确认"
                )
            }
            return try JSONDecoder().decode(TunnelProviderResponse.self, from: responseData)
        } catch {
            return TunnelProviderResponse(
                result: .failed,
                loadedConfigurationVersion: version,
                message: error.localizedDescription
            )
        }
    }

    func queryProviderStatus() async -> TunnelProviderResponse? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected
        else {
            return nil
        }
        let requestID = UUID()
        let message = TunnelProviderMessage(
            action: .queryStatus,
            configurationVersion: 0,
            requestID: requestID
        )
        do {
            let data = try JSONEncoder().encode(message)
            let responseData = try await send(data, through: session)
            guard let responseData else {
                lastError = "WLOC Extension 未返回身份握手"
                resetProviderIdentity()
                return nil
            }
            let response = try JSONDecoder().decode(
                TunnelProviderResponse.self,
                from: responseData
            )
            guard response.requestID == requestID else {
                throw VPNManagerError.providerIdentityMismatch(
                    message: "响应挑战值不匹配"
                )
            }
            guard response.providerBundleIdentifier
                    == configuration.tunnelProviderBundleIdentifier
            else {
                throw VPNManagerError.providerIdentityMismatch(
                    message: "Bundle Identifier 不匹配"
                )
            }
            guard response.providerBuildNumber == appBuildNumber else {
                throw VPNManagerError.providerIdentityMismatch(
                    message: """
                    App build \(appBuildNumber)，Extension build \
                    \(response.providerBuildNumber ?? "未知")
                    """
                )
            }
            guard response.configurationSchemaVersion
                    == Self.configurationSchemaVersion
            else {
                throw VPNManagerError.providerIdentityMismatch(
                    message: "配置协议版本不匹配"
                )
            }
            providerIdentityVerified = true
            providerBuildNumber = response.providerBuildNumber
            providerRuntimeStatus = response.runtimeStatus
            lastError = nil
            return response
        } catch {
            resetProviderIdentity()
            lastError = "Extension 状态检测失败：\(error.localizedDescription)"
            return nil
        }
    }

    func refreshSuccessfulConnectionStatus() async -> Bool {
        guard status == .connected else {
            return false
        }
        _ = await queryProviderStatus()
        return hasSuccessfulConnection
    }

    func waitForSuccessfulConnection() async -> Bool {
        while !Task.isCancelled {
            switch status {
            case .connecting:
                break
            case .connected:
                if await refreshSuccessfulConnectionStatus() {
                    return true
                }
            case .notConfigured, .disconnected, .disconnecting, .failed:
                return false
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    func refreshProviderDiagnostics() async {
        lastProviderDiagnostic = diagnosticStore?.load()

        guard status == .disconnected || status == .failed,
              let connection = manager?.connection
        else {
            return
        }
        if let disconnectError = await fetchLastDisconnectError(connection) {
            let nsError = disconnectError as NSError
            lastError = """
            网络断开错误（\(nsError.domain) \(nsError.code)）：\
            \(nsError.localizedDescription)
            """
        } else if let diagnostic = lastProviderDiagnostic,
                  diagnostic.phase.indicatesFailure {
            lastError = diagnostic.displayMessage
        }
    }

    private func apply(_ vpnStatus: NEVPNStatus) {
        switch vpnStatus {
        case .invalid:
            status = manager == nil ? .notConfigured : .disconnected
        case .disconnected:
            status = .disconnected
        case .connecting, .reasserting:
            status = .connecting
        case .connected:
            status = .connected
        case .disconnecting:
            status = .disconnecting
        @unknown default:
            status = .failed
        }
    }

    private func handleStatusChange(
        _ connection: NEVPNConnection
    ) async {
        let previousStatus = status
        apply(connection.status)
        let wasStartingOrConnected = previousStatus == .connecting
            || previousStatus == .connected
        let disconnectedUnexpectedly = status == .disconnected
            && wasStartingOrConnected
            && !userRequestedStop

        if disconnectedUnexpectedly {
            await refreshProviderDiagnostics()
            unexpectedDisconnectSequence += 1
        }
        if status == .connected {
            await verifyConnectedProvider()
        }
        if status == .disconnected {
            userRequestedStop = false
            resetProviderIdentity()
        }
    }

    private func verifyConnectedProvider() async {
        guard await queryProviderStatus() != nil else {
            lastError = lastError
                ?? "系统网络已连接，但无法验证当前 WLOC Extension"
            userRequestedStop = true
            manager?.connection.stopVPNTunnel()
            status = .failed
            unexpectedDisconnectSequence += 1
            return
        }
        guard configuration.tunnelMode != .localForwarding
                || providerRuntimeStatus?.engineRunning == true
        else {
            lastError = "WLOC Extension 身份正确，但本机授权 HTTPS 代理未运行"
            manager?.connection.stopVPNTunnel()
            status = .failed
            unexpectedDisconnectSequence += 1
            return
        }
    }

    private func resetProviderIdentity() {
        providerIdentityVerified = false
        providerBuildNumber = nil
        providerRuntimeStatus = nil
    }

    private func userFacingConfigurationError(_ error: Error) -> Error {
        let nsError = error as NSError
        let normalizedDescription = nsError.localizedDescription.lowercased()
        let isPermissionDenied = normalizedDescription.contains("permission denied")
            || (nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 10)
            || (nsError.domain == "NEVPNErrorDomain" && nsError.code == 5)

        if isPermissionDenied {
            return VPNManagerError.configurationPermissionDenied(
                systemError: "\(nsError.domain) \(nsError.code)"
            )
        }
        return VPNManagerError.configurationOperationFailed(
            message: configurationErrorMessage(
                prefix: "网络配置操作失败",
                error: error
            )
        )
    }

    private func configurationErrorMessage(prefix: String, error: Error) -> String {
        let nsError = error as NSError
        return "\(prefix)（\(nsError.domain) \(nsError.code)）：\(nsError.localizedDescription)"
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func remove(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func send(
        _ data: Data,
        through session: NETunnelProviderSession
    ) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ProviderMessageCompletionGate()
            do {
                try session.sendProviderMessage(data) { responseData in
                    gate.complete {
                        continuation.resume(returning: responseData)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 3
                ) {
                    gate.complete {
                        continuation.resume(
                            throwing: VPNManagerError.providerMessageTimedOut
                        )
                    }
                }
            } catch {
                gate.complete {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchLastDisconnectError(
        _ connection: NEVPNConnection
    ) async -> Error? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
    }
}

enum VPNManagerError: LocalizedError {
    case notConfigured
    case configurationUnavailable
    case configurationPermissionDenied(systemError: String)
    case configurationOperationFailed(message: String)
    case proxyEndpointMissing
    case providerIdentityMismatch(message: String)
    case providerMessageTimedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "网络尚未配置"
        case .configurationUnavailable:
            "无法创建网络配置"
        case let .configurationPermissionDenied(systemError):
            """
            系统拒绝保存网络配置（\(systemError)）。这通常表示当前安装包没有被系统识别为具有 \
            packet-tunnel-provider entitlement，或用户拒绝了系统的网络配置确认；与测试坐标、\
            127.0.0.1 地址无关。
            """
        case let .configurationOperationFailed(message):
            message
        case .proxyEndpointMissing:
            "尚未配置开发者控制的授权测试代理地址，已拒绝启动空隧道"
        case let .providerIdentityMismatch(message):
            "当前连接不是本 App build 对应的 WLOC Extension：\(message)"
        case .providerMessageTimedOut:
            "等待 WLOC Extension 响应超过 3 秒"
        }
    }
}

private final class ProviderMessageCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete(_ action: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        action()
    }
}
