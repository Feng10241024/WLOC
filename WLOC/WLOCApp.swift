// Modified from xiaobovlog/WLOC for place search, favorites, and public release. See NOTICE.
//
//  WLOCApp.swift
//  WLOC
//
//  Created by xiaobovlog on 2026/7/29.
//

import SwiftUI

@main
struct WLOCApp: App {
    @StateObject private var store: AppSettingsStore
    @StateObject private var initialLocationService: InitialTestLocationService
    @StateObject private var vpnManager: VPNManager
    @StateObject private var favoritesStore: FavoriteLocationsStore
    @StateObject private var selectionStore: LocationSelectionStore
    private let configuration: AppConfiguration

    init() {
        let configuration = AppConfiguration.load()
        let persistence = SettingsPersistenceService(
            defaults: DevelopmentServices.settingsDefaults(appGroupIdentifier: configuration.appGroupIdentifier)
        )
        let sharedConfiguration = SharedConfigurationService(persistence: persistence)
        let vpnManager = VPNManager(configuration: configuration)
        sharedConfiguration.notifier = vpnManager

        self.configuration = configuration
        _store = StateObject(
            wrappedValue: AppSettingsStore(
                persistence: persistence,
                sharedConfiguration: sharedConfiguration,
                tunnelMode: configuration.tunnelMode
            )
        )
        _initialLocationService = StateObject(
            wrappedValue: InitialTestLocationService()
        )
        _vpnManager = StateObject(wrappedValue: vpnManager)
        _favoritesStore = StateObject(wrappedValue: FavoriteLocationsStore(
            persistence: FavoriteLocationsPersistence(defaults: DevelopmentServices.favoritesDefaults)))
        _selectionStore = StateObject(wrappedValue: DevelopmentServices.makeSelectionStore())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                store: store,
                initialLocationService: initialLocationService,
                vpnManager: vpnManager,
                favoritesStore: favoritesStore,
                selectionStore: selectionStore,
                configuration: configuration
            )
        }
    }
}
