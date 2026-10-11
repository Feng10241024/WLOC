import Foundation

enum TunnelStartupPhase: String, Codable, Sendable {
    case startRequested
    case configurationLoaded
    case localProxyStarting
    case localProxyReady
    case localProxyProbeSucceeded
    case localProxyProbeFailed
    case networkSettingsApplying
    case networkSettingsApplied
    case tunnelDescriptorResolved
    case engineStarting
    case engineRunning
    case engineExited
    case outboundConnectionReady
    case trafficForwardingVerified
    case outboundConnectionFailed
    case startFailed

    var displayName: String {
        switch self {
        case .startRequested:
            "收到启动请求"
        case .configurationLoaded:
            "共享配置已加载"
        case .localProxyStarting:
            "正在启动本机授权 HTTPS 代理"
        case .localProxyReady:
            "本机授权 HTTPS 代理已就绪"
        case .localProxyProbeSucceeded:
            "本机授权 TLS 握手自检成功"
        case .localProxyProbeFailed:
            "本机授权 TLS 握手自检失败"
        case .networkSettingsApplying:
            "正在应用严格域名分流配置"
        case .networkSettingsApplied:
            "严格域名分流配置已应用"
        case .tunnelDescriptorResolved:
            "已找到 Packet Tunnel 接口"
        case .engineStarting:
            "正在启动用户态网络栈"
        case .engineRunning:
            "用户态网络栈已启动"
        case .engineExited:
            "用户态网络栈异常退出"
        case .outboundConnectionReady:
            "物理网络直连已就绪"
        case .trafficForwardingVerified:
            "已收到物理网络回包"
        case .outboundConnectionFailed:
            "物理网络直连失败"
        case .startFailed:
            "Packet Tunnel 启动失败"
        }
    }

    var indicatesFailure: Bool {
        self == .engineExited
            || self == .outboundConnectionFailed
            || self == .localProxyProbeFailed
            || self == .startFailed
    }
}

struct TunnelDiagnosticSnapshot: Codable, Equatable, Sendable {
    let phase: TunnelStartupPhase
    let timestamp: Date
    let errorType: String?
    let errorCode: Int?

    var displayMessage: String {
        var result = "Extension 最近阶段：\(phase.displayName)"
        if let errorType {
            result += "；错误类型：\(errorType)"
        }
        if let errorCode {
            result += "（\(errorCode)）"
        }
        return result
    }
}

struct TunnelDiagnosticStore: @unchecked Sendable {
    private static let key = "lastTunnelDiagnostic"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return nil
        }
        self.init(defaults: defaults)
    }

    func save(
        phase: TunnelStartupPhase,
        error: Error? = nil
    ) {
        let nsError = error as NSError?
        let snapshot = TunnelDiagnosticSnapshot(
            phase: phase,
            timestamp: Date(),
            errorType: nsError?.domain,
            errorCode: nsError?.code
        )
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    func load() -> TunnelDiagnosticSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else {
            return nil
        }
        return try? JSONDecoder().decode(
            TunnelDiagnosticSnapshot.self,
            from: data
        )
    }
}
