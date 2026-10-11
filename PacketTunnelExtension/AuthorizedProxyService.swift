import Foundation
import NetworkExtension

/// Produces a strict PAC configuration for a developer-controlled proxy.
/// The proxy server must independently enforce the same host/path allowlist.
struct AuthorizedProxyService {
    func makeDiagnosticNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )
        let ipv4 = NEIPv4Settings(
            addresses: ["192.0.2.2"],
            subnetMasks: ["255.255.255.255"]
        )
        // The diagnostic tunnel deliberately claims no routes. Its only job is
        // to prove that iOS can launch and communicate with this extension.
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        return settings
    }

    func makeLocalForwardingNetworkSettings(
        allowedHosts: Set<String>,
        proxyPort: UInt16
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )

        let ipv4 = NEIPv4Settings(
            addresses: ["192.0.2.2"],
            subnetMasks: ["255.255.255.255"]
        )
        // All non-authorized traffic stays on the physical interface. Only
        // proxy-aware URL loading for exact allowlisted hosts enters the
        // loopback proxy selected by the PAC below.
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.proxySettings = makePACProxySettings(
            proxyHost: "127.0.0.1",
            proxyPort: Int(proxyPort),
            allowedHosts: allowedHosts
        )
        return settings
    }

    func makeNetworkSettings(
        proxyURL: URL,
        allowedHosts: Set<String>
    ) throws -> NEPacketTunnelNetworkSettings {
        guard let proxyHost = proxyURL.host else {
            throw TunnelConfigurationError.invalidProxyURL
        }
        let proxyPort = proxyURL.port ?? 443
        let tunnelSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: proxyHost)

        let ipv4 = NEIPv4Settings(
            addresses: ["192.0.2.2"],
            subnetMasks: ["255.255.255.255"]
        )
        // No IP routes are captured. Proxy-aware URL loading uses the strict PAC;
        // every other connection continues directly and is not inspected.
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        tunnelSettings.ipv4Settings = ipv4

        tunnelSettings.proxySettings = makePACProxySettings(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            allowedHosts: allowedHosts
        )
        return tunnelSettings
    }

    private func makePACProxySettings(
        proxyHost: String,
        proxyPort: Int,
        allowedHosts: Set<String>
    ) -> NEProxySettings {
        let pacScript = AuthorizedProxyPAC.makeScript(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            allowedHosts: allowedHosts
        )
        let proxySettings = NEProxySettings()
        proxySettings.autoProxyConfigurationEnabled = true
        proxySettings.proxyAutoConfigurationJavaScript = pacScript
        proxySettings.excludeSimpleHostnames = true
        // With an empty IP-route set, iOS scopes proxy settings using
        // matchDomains. This API uses suffix matching, so it is only a coarse
        // activation filter; the PAC and the proxy both repeat exact equality
        // checks before any TLS session is accepted.
        proxySettings.matchDomains = allowedHosts.sorted()
        return proxySettings
    }
}
