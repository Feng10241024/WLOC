import Foundation

/// Minimal leaf configuration for the local, direct-forwarding data plane.
///
/// The configuration deliberately enables only a TUN inbound and a direct
/// outbound. Leaf requires a non-empty internal DNS configuration, so the
/// special `system` resolver is present without overriding the device's DNS
/// settings or hard-coding a public resolver. The configuration contains no
/// proxy server, health check, traffic sniffing, TLS interception, or telemetry
/// endpoint.
enum LeafTunnelConfiguration {
    static let directOutboundTag = "wloc-direct"
    static let tunnelInboundTag = "wloc-tun"
    static let tunnelMTU = 1_280

    static func make(tunnelFileDescriptor: Int32) throws -> String {
        guard tunnelFileDescriptor >= 0 else {
            throw LeafTunnelConfigurationError.invalidTunnelDescriptor
        }

        let configuration = Configuration(
            log: Log(level: "none"),
            dns: DNS(
                servers: ["system"],
                hosts: [:]
            ),
            inbounds: [
                Inbound(
                    tag: tunnelInboundTag,
                    protocolName: "tun",
                    settings: TunSettings(
                        fd: tunnelFileDescriptor,
                        mtu: tunnelMTU,
                        tun2socks: "lwip"
                    )
                )
            ],
            outbounds: [
                Outbound(
                    tag: directOutboundTag,
                    protocolName: "direct"
                )
            ],
            router: Router(
                domainResolve: false,
                rules: [
                    Rule(
                        inboundTag: [tunnelInboundTag],
                        target: directOutboundTag
                    )
                ]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        guard let result = String(data: data, encoding: .utf8) else {
            throw LeafTunnelConfigurationError.encodingFailed
        }
        return result
    }

    private struct Configuration: Encodable {
        let log: Log
        let dns: DNS
        let inbounds: [Inbound]
        let outbounds: [Outbound]
        let router: Router
    }

    private struct Log: Encodable {
        let level: String
    }

    private struct DNS: Encodable {
        let servers: [String]
        let hosts: [String: [String]]
    }

    private struct Inbound: Encodable {
        let tag: String
        let protocolName: String
        let settings: TunSettings

        enum CodingKeys: String, CodingKey {
            case tag
            case protocolName = "protocol"
            case settings
        }
    }

    private struct TunSettings: Encodable {
        let fd: Int32
        let mtu: Int
        let tun2socks: String
    }

    private struct Outbound: Encodable {
        let tag: String
        let protocolName: String

        enum CodingKeys: String, CodingKey {
            case tag
            case protocolName = "protocol"
        }
    }

    private struct Router: Encodable {
        let domainResolve: Bool
        let rules: [Rule]
    }

    private struct Rule: Encodable {
        let inboundTag: [String]
        let target: String
    }
}

enum LeafTunnelConfigurationError: LocalizedError, Equatable {
    case invalidTunnelDescriptor
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidTunnelDescriptor:
            "未找到 Packet Tunnel 的有效文件描述符"
        case .encodingFailed:
            "无法生成 leaf 直连配置"
        }
    }
}
