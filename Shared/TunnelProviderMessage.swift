import Foundation

enum TunnelMessageAction: String, Codable, Sendable {
    case reloadConfiguration
    case queryStatus
}

struct TunnelProviderMessage: Codable, Sendable {
    let action: TunnelMessageAction
    let configurationVersion: Int
    let requestID: UUID?

    init(
        action: TunnelMessageAction,
        configurationVersion: Int,
        requestID: UUID? = nil
    ) {
        self.action = action
        self.configurationVersion = configurationVersion
        self.requestID = requestID
    }
}

struct LocalProxyRuntimeStatus: Codable, Equatable, Sendable {
    let acceptedTCPConnections: UInt64
    let acceptedUDPFlows: UInt64
    let tcpOutboundAttempts: UInt64
    let tcpOutboundReady: UInt64
    let tcpResponses: UInt64
    let tcpFailures: UInt64
    let udpOutboundAttempts: UInt64
    let udpOutboundReady: UInt64
    let udpResponses: UInt64
    let udpFailures: UInt64
    let lastErrorType: String?
    let lastErrorCode: Int?
}

struct AuthorizedRewriteProxyRuntimeStatus: Codable, Equatable, Sendable {
    let listenerReady: Bool
    let acceptedConnections: UInt64
    let rejectedConnections: UInt64
    let successfulTLSHandshakes: UInt64
    let rewrittenRequests: UInt64
    let passThroughRequests: UInt64
    let failures: UInt64
    let lastErrorType: String?
}

struct TunnelRuntimeStatus: Codable, Equatable, Sendable {
    let mode: TunnelOperatingMode
    let engineRunning: Bool
    let openSourceCore: String?
    let lastDirectActivitySeconds: UInt32?
    let localSocksPort: UInt16?
    let transmittedPackets: UInt64
    let transmittedBytes: UInt64
    let receivedPackets: UInt64
    let receivedBytes: UInt64
    let localProxy: LocalProxyRuntimeStatus?
    let rewriteProxy: AuthorizedRewriteProxyRuntimeStatus?

    init(
        mode: TunnelOperatingMode,
        engineRunning: Bool,
        openSourceCore: String? = nil,
        lastDirectActivitySeconds: UInt32? = nil,
        localSocksPort: UInt16?,
        transmittedPackets: UInt64,
        transmittedBytes: UInt64,
        receivedPackets: UInt64,
        receivedBytes: UInt64,
        localProxy: LocalProxyRuntimeStatus? = nil,
        rewriteProxy: AuthorizedRewriteProxyRuntimeStatus? = nil
    ) {
        self.mode = mode
        self.engineRunning = engineRunning
        self.openSourceCore = openSourceCore
        self.lastDirectActivitySeconds = lastDirectActivitySeconds
        self.localSocksPort = localSocksPort
        self.transmittedPackets = transmittedPackets
        self.transmittedBytes = transmittedBytes
        self.receivedPackets = receivedPackets
        self.receivedBytes = receivedBytes
        self.localProxy = localProxy
        self.rewriteProxy = rewriteProxy
    }
}

struct TunnelProviderResponse: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable {
        case configurationLoaded
        case status
        case rejectedStaleConfiguration
        case invalidConfiguration
        case failed
    }

    let result: Result
    let loadedConfigurationVersion: Int
    let message: String?
    let runtimeStatus: TunnelRuntimeStatus?
    let requestID: UUID?
    let providerBundleIdentifier: String?
    let providerBuildNumber: String?
    let configurationSchemaVersion: Int?

    init(
        result: Result,
        loadedConfigurationVersion: Int,
        message: String?,
        runtimeStatus: TunnelRuntimeStatus? = nil,
        requestID: UUID? = nil,
        providerBundleIdentifier: String? = nil,
        providerBuildNumber: String? = nil,
        configurationSchemaVersion: Int? = nil
    ) {
        self.result = result
        self.loadedConfigurationVersion = loadedConfigurationVersion
        self.message = message
        self.runtimeStatus = runtimeStatus
        self.requestID = requestID
        self.providerBundleIdentifier = providerBundleIdentifier
        self.providerBuildNumber = providerBuildNumber
        self.configurationSchemaVersion = configurationSchemaVersion
    }
}
