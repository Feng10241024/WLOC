import Foundation
import UIKit

enum LocationShortcutLaunchResult: Equatable {
    case openedShortcut
    case openedInstaller
    case openedAppStore
    case failed
}

@MainActor
enum LocationShortcutLauncher {
    static let shortcutName = "定位服务"
    static let sharedShortcutURL = URL(
        string: "https://www.icloud.com/shortcuts/87d30da4cb8f4acc89ab11e35c048227"
    )!
    static let shortcutsAppStoreURL = URL(
        string: "https://apps.apple.com/cn/app/shortcuts/id1462947752"
    )!
    static let shortcutsAppURL = URL(string: "shortcuts://")!

    static var runURL: URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName)
        ]
        return components.url
    }

    static func prepare() async -> LocationShortcutLaunchResult {
        await prepare(
            canOpenURL: { UIApplication.shared.canOpenURL($0) },
            openURL: { url in
                await UIApplication.shared.open(url)
            }
        )
    }

    static func prepare(
        canOpenURL: (URL) -> Bool,
        openURL: (URL) async -> Bool
    ) async -> LocationShortcutLaunchResult {
        if canOpenURL(shortcutsAppURL) {
            if await openURL(sharedShortcutURL) {
                return .openedInstaller
            }
            return .failed
        }
        if await openURL(shortcutsAppStoreURL) {
            return .openedAppStore
        }
        return .failed
    }

    static func runShortcut() async -> LocationShortcutLaunchResult {
        await runShortcut { url in
            await UIApplication.shared.open(url)
        }
    }

    static func runShortcut(
        using openURL: (URL) async -> Bool
    ) async -> LocationShortcutLaunchResult {
        guard let runURL else {
            return .failed
        }
        if await openURL(runURL) {
            return .openedShortcut
        }
        if await openURL(shortcutsAppStoreURL) {
            return .openedAppStore
        }
        return .failed
    }

    static func openInstaller() async -> LocationShortcutLaunchResult {
        await openInstaller { url in
            await UIApplication.shared.open(url)
        }
    }

    static func openInstaller(
        using openURL: (URL) async -> Bool
    ) async -> LocationShortcutLaunchResult {
        await openURL(sharedShortcutURL) ? .openedInstaller : .failed
    }
}
