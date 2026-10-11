import Foundation

enum CoordinateAxis {
    case longitude
    case latitude
}

enum CoordinateDisplayFormatter {
    static func decimal(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "未设置"
        }
        return String(format: "%.6f°", value)
    }

    static func degreesMinutesSeconds(
        _ value: Double?,
        axis: CoordinateAxis
    ) -> String? {
        guard let value, value.isFinite else {
            return nil
        }

        // Round the complete angle first so values such as 59.9999 seconds
        // correctly carry into the next minute instead of displaying 60 seconds.
        let millisecondsPerDegree: Int64 = 3_600_000
        let totalMilliseconds = Int64(
            (abs(value) * Double(millisecondsPerDegree)).rounded()
        )
        let degrees = totalMilliseconds / millisecondsPerDegree
        let afterDegrees = totalMilliseconds % millisecondsPerDegree
        let minutes = afterDegrees / 60_000
        let secondsMilliseconds = afterDegrees % 60_000
        let seconds = Double(secondsMilliseconds) / 1_000

        let direction: String
        switch axis {
        case .longitude:
            direction = value < 0 ? "西经" : "东经"
        case .latitude:
            direction = value < 0 ? "南纬" : "北纬"
        }

        return String(
            format: "%@ %lld°%lld′%.3f″",
            direction,
            degrees,
            minutes,
            seconds
        )
    }
}
