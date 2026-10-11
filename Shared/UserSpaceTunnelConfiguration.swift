#if LEGACY_LOCAL_SOCKS
import Darwin
import Foundation

enum UserSpaceTunnelConfiguration {
    static func make(
        socksHost: String,
        socksPort: UInt16
    ) throws -> String {
        guard socksPort > 0 else {
            throw UserSpaceTunnelConfigurationError.invalidSocksPort
        }
        guard let address = parsedIPv4Address(socksHost) else {
            throw UserSpaceTunnelConfigurationError.invalidSocksHost(
                socksHost
            )
        }
        let hostOrderAddress = UInt32(bigEndian: address.s_addr)
        let firstOctet = hostOrderAddress >> 24
        guard firstOctet != 127 else {
            throw UserSpaceTunnelConfigurationError.loopbackSocksHost
        }
        guard hostOrderAddress != 0,
              hostOrderAddress != UInt32.max,
              firstOctet != 0,
              firstOctet < 224,
              hostOrderAddress & 0xFFFF_0000 != 0xA9FE_0000
        else {
            throw UserSpaceTunnelConfigurationError.invalidSocksHost(
                socksHost
            )
        }

        return """
        tunnel:
          mtu: 1500
          ipv4: 198.18.0.1
          ipv6: 'fc00::1'
        socks5:
          port: \(socksPort)
          address: '\(socksHost)'
          udp: 'udp'
          udp-address: '\(socksHost)'
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 512
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: stderr
          log-level: error
        """
    }

    private static func parsedIPv4Address(_ value: String) -> in_addr? {
        var address = in_addr()
        let result = value.withCString {
            inet_pton(AF_INET, $0, &address)
        }
        return result == 1 ? address : nil
    }
}

enum UserSpaceTunnelConfigurationError: LocalizedError, Equatable {
    case invalidSocksHost(String)
    case loopbackSocksHost
    case invalidSocksPort

    var errorDescription: String? {
        switch self {
        case let .invalidSocksHost(host):
            "本机 SOCKS 地址必须是有效的 IPv4：\(host)"
        case .loopbackSocksHost:
            "本机 SOCKS 地址不能使用回环地址"
        case .invalidSocksPort:
            "本机 SOCKS 端口必须大于 0"
        }
    }
}
#endif
