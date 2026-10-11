import Foundation

struct AuthorizedProxyPAC {
    static func makeScript(
        proxyHost: String,
        proxyPort: Int,
        allowedHosts: Set<String>
    ) -> String {
        let conditions = allowedHosts.sorted().map { host in
            #"host === "\#(escapeJavaScript(host))""#
        }.joined(separator: " || ")
        return """
        function FindProxyForURL(url, host) {
            host = host.toLowerCase();
            if (url.indexOf("https://") !== 0) {
                return "DIRECT";
            }
            if (\(conditions)) {
                return "PROXY \(escapeJavaScript(proxyHost)):\(proxyPort)";
            }
            return "DIRECT";
        }
        """
    }

    private static func escapeJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }
}
