import Foundation

enum TunnelOperatingMode: String, Codable, Sendable {
    /// Starts the provider without claiming routes or configuring a proxy.
    /// This mode only verifies entitlement, extension registration, lifecycle,
    /// and provider-message communication.
    case diagnosticNoTraffic

    /// Isolated-device mode. Claims no IP routes, publishes a strict PAC for
    /// exact authorized hosts, and terminates only those HTTPS test sessions
    /// in the extension's loopback rewrite proxy.
    case localForwarding

    /// Uses a developer-controlled proxy for the strictly authorized hosts.
    case authorizedRemoteProxy

    var displayName: String {
        switch self {
        case .diagnosticNoTraffic:
            "网络诊断模式（不接管流量）"
        case .localForwarding:
            "本机授权 HTTPS 重写"
        case .authorizedRemoteProxy:
            "授权远端代理模式"
        }
    }
}
