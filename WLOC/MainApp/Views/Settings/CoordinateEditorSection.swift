// Modified from xiaobovlog/WLOC for place search, favorites, and public release. See NOTICE.
import CoreLocation
import SwiftUI

struct CoordinateEditorSection: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var vpnManager: VPNManager

    @State private var longitude = ""
    @State private var latitude = ""
    @State private var accuracy = ""
    @State private var validationMessage: String?

    var body: some View {
        Section("手动编辑经度、纬度和精度") {
            coordinateField("经度（GCJ-02，-180...180）", text: $longitude)
            coordinateField("纬度（GCJ-02，-90...90）", text: $latitude)
            coordinateField("精度（米，> 0）", text: $accuracy)

            Button("使用此位置") {
                save()
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(validationMessage.hasPrefix("已") ? .green : .red)
            }
        }
        .onAppear(perform: loadFromStore)
        .onChange(of: store.mockLongitude) { _ in loadFromStore() }
        .onChange(of: store.mockLatitude) { _ in loadFromStore() }
        .onChange(of: store.mockAccuracy) { _ in loadFromStore() }
    }

    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func save() {
        guard let longitudeValue = parse(longitude),
              let latitudeValue = parse(latitude),
              let accuracyValue = parse(accuracy)
        else {
            validationMessage = "请输入有效数字"
            return
        }
        let gcj02Coordinate = CLLocationCoordinate2D(
            latitude: latitudeValue,
            longitude: longitudeValue
        )
        guard CLLocationCoordinate2DIsValid(gcj02Coordinate) else {
            validationMessage = "经纬度或精度超出合法范围"
            return
        }
        let wgs84Coordinate = ChinaMapCoordinateConverter.wgs84(
            fromGCJ02: gcj02Coordinate
        )
        let candidate = LocationConfiguration(
            longitude: wgs84Coordinate.longitude,
            latitude: wgs84Coordinate.latitude,
            accuracy: accuracyValue
        )
        guard candidate.isValid else {
            validationMessage = "经纬度或精度超出合法范围"
            return
        }
        Task {
            let outcome = await store.updateMockLocationWithApplicationResult(
                longitude: wgs84Coordinate.longitude,
                latitude: wgs84Coordinate.latitude,
                accuracy: accuracyValue
            )
            if outcome.saved {
                validationMessage = "已转换为 WGS-84 并同步配置"
                _ = await LocationShortcutLauncher.runShortcut()
            }
        }
    }

    private func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "."))
    }

    private func loadFromStore() {
        if let storedLongitude = store.mockLongitude,
           let storedLatitude = store.mockLatitude {
            let gcj02Coordinate = ChinaMapCoordinateConverter.gcj02(
                fromWGS84: CLLocationCoordinate2D(
                    latitude: storedLatitude,
                    longitude: storedLongitude
                )
            )
            longitude = String(format: "%.6f", gcj02Coordinate.longitude)
            latitude = String(format: "%.6f", gcj02Coordinate.latitude)
        } else {
            longitude = ""
            latitude = ""
        }
        accuracy = String(format: "%.1f", store.mockAccuracy)
    }
}
