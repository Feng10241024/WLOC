// Modified from xiaobovlog/WLOC for place search, favorites, and public release. See NOTICE.
import CoreLocation
import SwiftUI

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: AppSettingsStore
    @StateObject private var searchStore = DevelopmentServices.makeSearchStore()
    @ObservedObject var favoritesStore: FavoriteLocationsStore
    @ObservedObject var selectionStore: LocationSelectionStore
    let isApplying: Bool
    let onUse: (LocationSelection) -> Void

    @State private var mapCenterCommand: MapCenterCommand?
    @State private var mapZoomCommand: MapZoomCommand?
    @State private var toastMessage: String?
    @State private var mapErrorMessage: String?
    @State private var mapReloadID = UUID()
    @State private var mapRetryTask: Task<Void, Never>?
    @State private var preserveMapZoom = false

    private var mockCoordinate: CLLocationCoordinate2D? {
        guard let longitude = store.mockLongitude,
              let latitude = store.mockLatitude
        else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var selectedSearchResult: PlaceSearchResult? {
        guard let selection = selectionStore.selection else { return nil }
        return PlaceSearchResult(id: selection.id, name: selection.name,
            address: selection.address ?? "", mapCoordinate: selection.displayCoordinate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PlaceSearchSection(store: searchStore, onSelect: showSearchResult)

                    ZStack(alignment: .bottomTrailing) {
                        LocationMapView(
                            mockLocationWGS84: mockCoordinate,
                            centerCommand: mapCenterCommand,
                            zoomCommand: mapZoomCommand,
                            searchResult: selectedSearchResult,
                            onLongPress: selectMapLocation,
                            onMapError: handleMapError,
                            onMapLoaded: handleMapLoaded
                        )
                        .id(mapReloadID)

                        MapZoomButtons(
                            zoomIn: { mode in
                                mapZoomCommand = MapZoomCommand(
                                    direction: .zoomIn,
                                    mode: mode
                                )
                            },
                            zoomOut: { mode in
                                mapZoomCommand = MapZoomCommand(
                                    direction: .zoomOut,
                                    mode: mode
                                )
                            },
                            centerOnTestLocation: {
                                guard let mockCoordinate else {
                                    toastMessage = "请先长按地图设置测试位置"
                                    return
                                }
                                mapCenterCommand = MapCenterCommand(
                                    coordinateWGS84: mockCoordinate
                                )
                            }
                        )
                        .padding(12)
                    }
                    .frame(minHeight: 390)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Text("长按选择地点，点击“使用此位置”后应用")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("蓝色标记是已选地点，红色标记是当前测试位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LocationStatusCard(store: store)

                    if let message = store.lastErrorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if let message = store.locationMessage {
                        Label(message, systemImage: "checkmark.circle")
                            .foregroundStyle(.primary)
                    }
                    if let mapErrorMessage {
                        Label("地图加载失败：\(mapErrorMessage)", systemImage: "map")
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("测试位置")
            .safeAreaInset(edge: .bottom) {
                if let selection = selectionStore.selection {
                    SelectedLocationCard(selection: selection,
                        favorites: favoritesStore,
                        isResolvingAddress: selectionStore.isResolvingAddress,
                        isApplying: isApplying, onUse: onUse)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                }
            }
            .onAppear { centerOnSelection() }
            .onChange(of: selectionStore.selection?.id) { _ in centerOnSelection() }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, mapErrorMessage != nil else {
                    return
                }
                reloadMapAndRetry()
            }
            .onDisappear {
                searchStore.cancelAndClear()
                mapRetryTask?.cancel()
                mapRetryTask = nil
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation {
                                self.toastMessage = nil
                            }
                        }
                }
            }
        }
    }

    private func handleMapError(_ message: String) {
        mapErrorMessage = message
        scheduleMapRetriesIfNeeded()
    }

    private func handleMapLoaded() {
        mapErrorMessage = nil
        mapRetryTask?.cancel()
        mapRetryTask = nil
    }

    private func reloadMapAndRetry() {
        mapRetryTask?.cancel()
        mapRetryTask = nil
        mapReloadID = UUID()
        scheduleMapRetriesIfNeeded()
    }

    private func scheduleMapRetriesIfNeeded() {
        guard mapRetryTask == nil else {
            return
        }
        mapRetryTask = Task { @MainActor in
            for delay in [1.0, 2.0, 4.0] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard mapErrorMessage != nil else {
                    return
                }
                mapReloadID = UUID()
            }
            mapRetryTask = nil
        }
    }

    private func selectMapLocation(_ coordinate: CLLocationCoordinate2D) {
        preserveMapZoom = true
        selectionStore.select(LocationSelection(name: "地图选点",
            coordinateWGS84: LocationCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
            accuracy: store.mockAccuracy), resolveAddress: true)
    }

    private func showSearchResult(_ result: PlaceSearchResult) {
        selectionStore.select(.searchResult(result, accuracy: store.mockAccuracy))
        searchStore.cancelAndClear()
    }

    private func centerOnSelection() {
        guard let selection = selectionStore.selection else { return }
        mapCenterCommand = MapCenterCommand(coordinateWGS84: selection.coordinateWGS84.coreLocationCoordinate,
            visibleDistance: preserveMapZoom ? nil : 2_000)
        preserveMapZoom = false
    }
}
