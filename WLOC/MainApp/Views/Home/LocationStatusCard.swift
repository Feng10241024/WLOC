// Modified from xiaobovlog/WLOC for place search, favorites, and public release. See NOTICE.
import CoreLocation
import SwiftUI

struct LocationStatusCard: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前测试位置")
                .font(.headline)
            coordinateRow("经度", displayCoordinate?.longitude, axis: .longitude)
            coordinateRow("纬度", displayCoordinate?.latitude, axis: .latitude)
            HStack {
                Text("精度")
                Spacer()
                Text("\(store.mockAccuracy, specifier: "%.1f") 米")
                    .monospacedDigit()
                    .accessibilityIdentifier("current.accuracy")
            }
            HStack {
                Label(store.vpnStatus.rawValue, systemImage: "network")
                Spacer()
                Label(
                    rewriteStatusText,
                    systemImage: store.rewriteEnabled ? "checkmark.shield" : "shield.slash"
                )
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var displayCoordinate: CLLocationCoordinate2D? {
        guard let longitude = store.mockLongitude,
              let latitude = store.mockLatitude
        else {
            return nil
        }
        return ChinaMapCoordinateConverter.gcj02(
            fromWGS84: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            )
        )
    }

    private var rewriteStatusText: String {
        if store.tunnelMode == .diagnosticNoTraffic {
            return store.rewriteEnabled ? "诊断通道已开启" : "诊断通道已关闭"
        }
        if store.tunnelMode == .localForwarding {
            return store.rewriteEnabled ? "本机转发已开启" : "本机转发已关闭"
        }
        return store.rewriteEnabled ? "重写已开启" : "重写已关闭"
    }

    private func coordinateRow(
        _ title: String,
        _ value: Double?,
        axis: CoordinateAxis
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(CoordinateDisplayFormatter.decimal(value))
                    .monospacedDigit()
                    .accessibilityIdentifier(title == "经度" ? "current.longitude" : "current.latitude")
                if let degreesMinutesSeconds = CoordinateDisplayFormatter
                    .degreesMinutesSeconds(value, axis: axis) {
                    Text(degreesMinutesSeconds)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
