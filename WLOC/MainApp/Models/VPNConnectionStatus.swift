import Foundation

enum VPNConnectionStatus: String, Codable, Sendable {
    case notConfigured = "未配置"
    case disconnected = "已断开"
    case connecting = "正在连接"
    case connected = "已连接"
    case disconnecting = "正在断开"
    case failed = "连接失败"
}
