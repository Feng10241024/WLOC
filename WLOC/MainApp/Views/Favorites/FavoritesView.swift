import SwiftUI

struct FavoritesView: View {
    @ObservedObject var favorites: FavoriteLocationsStore
    let defaultAccuracy: Double
    let isApplying: Bool
    let onChooseMap: () -> Void
    let onUse: (LocationSelection) -> Void
    @State private var editor: FavoriteEditor?
    @State private var deletingFavorite: FavoriteLocation?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        addButton("地图选点", image: "map", action: onChooseMap)
                        addButton("地点名称", image: "magnifyingglass") { editor = .add(.search) }
                        addButton("输入坐标", image: "number") { editor = .add(.coordinates) }
                    }
                    .listRowInsets(EdgeInsets(top: 18, leading: 8, bottom: 18, trailing: 8))
                } header: { Text("添加收藏") }

                Section {
                    if favorites.favorites.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                            Text("还没有收藏").font(.headline)
                            Text("从地图、地点名称或坐标添加，保存后随时使用")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(favorites.favorites) { favorite in
                        favoriteRow(favorite)
                    }
                } header: { Text("我的收藏（\(favorites.favorites.count)）") }

                if let error = favorites.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("收藏")
            .sheet(item: $editor) { editor in
                switch editor {
                case let .add(method):
                    AddFavoriteView(method: method, favorites: favorites, defaultAccuracy: defaultAccuracy)
                case let .rename(favorite):
                    RenameFavoriteView(favorite: favorite, favorites: favorites)
                }
            }
            .confirmationDialog("删除这个收藏？", isPresented: deletionPresented,
                                presenting: deletingFavorite) { favorite in
                Button("删除收藏", role: .destructive) {
                    favorites.remove(favorite)
                    deletingFavorite = nil
                }
                Button("取消", role: .cancel) { deletingFavorite = nil }
            } message: { favorite in Text("将删除“\(favorite.name)”。") }
        }
    }

    private func addButton(_ title: String, image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: image).font(.title2)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain).foregroundStyle(.tint)
        .accessibilityIdentifier("favorites.add.\(image)")
    }

    private func favoriteRow(_ favorite: FavoriteLocation) -> some View {
        let selection = LocationSelection.favorite(favorite, fallbackAccuracy: defaultAccuracy)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(favorite.name).font(.headline)
                    .accessibilityIdentifier("favorite.name")
                Spacer()
                Menu {
                    Button("修改名称") { editor = .rename(favorite) }
                    Button("删除收藏", role: .destructive) { deletingFavorite = favorite }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 32)
                }
                .accessibilityLabel("管理收藏：\(favorite.name)")
            }
            if let address = favorite.address, !address.isEmpty {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(selection.coordinateText).font(.caption).monospacedDigit()
            HStack {
                Text("精度 \(selection.accuracy, specifier: "%.1f") 米")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("使用此位置") { onUse(selection) }
                    .buttonStyle(.bordered)
                    .disabled(isApplying)
                    .accessibilityIdentifier("favorite.use")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("favorite.row")
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletingFavorite != nil }, set: { if !$0 { deletingFavorite = nil } })
    }
}

enum FavoriteAddMethod: String, Identifiable {
    case search, coordinates
    var id: String { rawValue }
}

private enum FavoriteEditor: Identifiable {
    case add(FavoriteAddMethod)
    case rename(FavoriteLocation)
    var id: String {
        switch self {
        case let .add(method): "add-" + method.rawValue
        case let .rename(favorite): "rename-" + favorite.id.uuidString
        }
    }
}
