import Foundation

enum SharedConstants {
    static let appGroupIdentifier = "group.com.xx.wloc"
    static let tunnelProviderBundleIdentifier = "com.xx.wloc.PacketTunnel"

    /// Developer-owned WLOC-compatible endpoints whose protobuf responses may
    /// be rewritten with the test location selected in this App.
    static let wlocResponseRewriteHosts: Set<String> = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com"
    ]
    /// This is the only default TLS interception allowlist. Production builds
    /// should load an organization-approved list from managed configuration.
    static let defaultAllowedHosts = wlocResponseRewriteHosts

    static let wlocResponseRewritePath = "/clls/wloc"
    static let defaultAccuracy = 5.0
}
