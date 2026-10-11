// Modified from xiaobovlog/WLOC for place search, favorites, and public release. See NOTICE.
import Combine
import CoreLocation
import SwiftUI

struct RootTabView: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var initialLocationService: InitialTestLocationService
    @ObservedObject var vpnManager: VPNManager
    @ObservedObject var favoritesStore: FavoriteLocationsStore
    @ObservedObject var selectionStore: LocationSelectionStore
    let configuration: AppConfiguration
    @State private var selectedTab = RootTab.home
    @State private var isApplying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                store: store, favoritesStore: favoritesStore,
                selectionStore: selectionStore, isApplying: isApplying, onUse: useLocation
            )
                .tabItem {
                    Label("首页", systemImage: "map")
                }
                .tag(RootTab.home)

            FavoritesView(favorites: favoritesStore, defaultAccuracy: store.mockAccuracy,
                isApplying: isApplying, onChooseMap: { selectedTab = .home }, onUse: useLocation)
                .tabItem { Label("收藏", systemImage: "star") }
                .tag(RootTab.favorites)

            SettingsView(
                store: store,
                vpnManager: vpnManager,
                configuration: configuration,
                isActive: selectedTab == .settings
            )
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
            .tag(RootTab.settings)
        }
        .onReceive(vpnManager.$status) { status in
            store.vpnStatus = status
        }
        .onReceive(initialLocationService.$location.compactMap { $0 }) { location in
            Task {
                _ = await store.initializeTestLocationIfNeeded(
                    longitude: location.coordinate.longitude,
                    latitude: location.coordinate.latitude
                )
            }
        }
        .onReceive(initialLocationService.$errorMessage.compactMap { $0 }) { message in
            guard store.mockLocation == nil else {
                return
            }
            store.reportError(message)
        }
        .onReceive(vpnManager.$unexpectedDisconnectSequence) { sequence in
            guard sequence > 0 else {
                return
            }
            Task {
                await store.setRewriteEnabled(false)
                store.reportError(
                    vpnManager.lastError
                        ?? "网络启动失败或意外断开，请查看设置页的 Extension 诊断"
                )
            }
        }
        .task {
            guard !DevelopmentServices.isUITesting else { return }
            if store.mockLocation == nil {
                initialLocationService.requestLocationIfNeeded()
            }
            await vpnManager.loadConfiguration()
            guard store.rewriteEnabled else {
                return
            }
            if configuration.tunnelMode == .localForwarding,
               vpnManager.status != .connected,
               vpnManager.status != .connecting {
                await store.setRewriteEnabled(false)
                store.reportError(
                    "上次本机转发未保持连接，已关闭自动重试"
                )
                return
            }

            let hasRequiredLocation =
                configuration.tunnelMode == .diagnosticNoTraffic
                || store.mockLocation != nil
            guard hasRequiredLocation,
                  vpnManager.status != .connected,
                  vpnManager.status != .connecting
            else {
                return
            }
            do {
                try await vpnManager.installConfigurationIfNeeded()
                try await vpnManager.start()
            } catch {
                store.reportError("恢复测试网络失败：\(error.localizedDescription)")
            }
        }
    }

    private func useLocation(_ selection: LocationSelection) {
        guard !isApplying else { return }
        isApplying = true
        Task {
            defer { isApplying = false }
            let outcome = await store.updateMockLocationWithApplicationResult(
                longitude: selection.coordinateWGS84.longitude,
                latitude: selection.coordinateWGS84.latitude, accuracy: selection.accuracy)
            guard outcome.saved else { return }
            selectionStore.select(selection)
            selectedTab = .home
            if !DevelopmentServices.isUITesting {
                _ = await LocationShortcutLauncher.runShortcut()
            }
        }
    }
}

private enum RootTab: Hashable {
    case home
    case favorites
    case settings
}
