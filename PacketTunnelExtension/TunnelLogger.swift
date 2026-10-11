import Foundation
import OSLog

struct TunnelLogger {
    private let logger = Logger(
        subsystem: "com.xiaobovlog.WLOC.PacketTunnel",
        category: "AuthorizedRewrite"
    )

    func wlocResponseMatched(
        host: String,
        path: String,
        location: SharedLocationConfiguration,
        statistics: WLOCRewriteStatistics
    ) {
        logger.info(
            "rule=Authorized WLOC Protobuf Response host=\(host, privacy: .public) path=\(path, privacy: .public) matched=true longitude=\(location.longitude, privacy: .public) latitude=\(location.latitude, privacy: .public) accuracy=\(location.accuracy, privacy: .public) locations=\(statistics.locations, privacy: .public) wifi=\(statistics.wifiRecords, privacy: .public) cellular=\(statistics.cellularRecords, privacy: .public) skipped=\(statistics.skippedRecords, privacy: .public)"
        )
    }

    func error(type: String) {
        logger.error("errorType=\(type, privacy: .public)")
    }
}
