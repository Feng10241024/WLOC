import Foundation

enum CertificateValidationStatus: Equatable, Sendable {
    case notChecked
    case checking
    case valid
    case untrusted
    case networkFailure(String)
    case serviceUnavailable(String)

    var displayText: String {
        switch self {
        case .notChecked:
            "未检测"
        case .checking:
            "检测中"
        case .valid:
            "测试证书已安装并可正常使用"
        case .untrusted:
            "测试证书尚未安装或尚未开启完全信任"
        case let .networkFailure(message):
            "网络连接失败：\(message)"
        case let .serviceUnavailable(message):
            "验证服务不可用：\(message)"
        }
    }
}
