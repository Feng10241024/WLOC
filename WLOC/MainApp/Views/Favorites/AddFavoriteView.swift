import SwiftUI

struct AddFavoriteView: View {
    let method: FavoriteAddMethod
    @ObservedObject var favorites: FavoriteLocationsStore
    let defaultAccuracy: Double
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = DevelopmentServices.makeSearchStore()
    @State private var name = ""
    @State private var longitude = ""
    @State private var latitude = ""
    @State private var accuracy = ""
    @State private var validationMessage: String?
    @FocusState private var focusedField: String?

    var body: some View {
        NavigationStack {
            Group {
                if method == .search {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("搜索地点，确认地址后直接收藏")
                                .font(.subheadline).foregroundStyle(.secondary)
                            PlaceSearchSection(store: search, selectionHint: "收藏这个地点") { result in
                                if favorites.add(.searchResult(result, accuracy: defaultAccuracy)) {
                                    dismiss()
                                }
                            }
                            errorText
                        }.padding()
                    }
                } else {
                    Form {
                        Section {
                            numberField("经度", text: $longitude, id: "favorite.longitude")
                            numberField("纬度", text: $latitude, id: "favorite.latitude")
                            numberField("精度（米）", text: $accuracy, id: "favorite.accuracy")
                        } header: {
                            Text("经纬度和精度")
                        } footer: {
                            Text("输入方式与设置页的手动编辑相同，精度需大于 0。")
                        }
                        Section {
                            TextField("收藏名称（可不填）", text: $name)
                                .focused($focusedField, equals: "name")
                                .accessibilityIdentifier("favorite.newName")
                            Button("加入收藏") { saveCoordinates() }
                                .accessibilityIdentifier("favorite.saveCoordinates")
                        }
                        Section { errorText }
                    }
                }
            }
            .navigationTitle(method == .search ? "按地点名称添加" : "按坐标添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .onAppear { accuracy = String(format: "%.1f", defaultAccuracy) }
        }
    }

    private var errorText: some View {
        Group {
            if let error = validationMessage ?? favorites.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("favorite.validationError")
            }
        }
    }

    private func numberField(_ title: String, text: Binding<String>, id: String) -> some View {
        HStack {
            Text(title).frame(width: 88, alignment: .leading)
            TextField(title, text: text)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(id)
                .focused($focusedField, equals: id)
        }
    }

    private func saveCoordinates() {
        do {
            let selection = try LocationSelection.manual(longitude: longitude, latitude: latitude,
                accuracy: accuracy, name: name)
            if favorites.add(selection) { dismiss() }
        } catch { validationMessage = error.localizedDescription }
    }
}

struct RenameFavoriteView: View {
    let favorite: FavoriteLocation
    @ObservedObject var favorites: FavoriteLocationsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(favorite: FavoriteLocation, favorites: FavoriteLocationsStore) {
        self.favorite = favorite
        self.favorites = favorites
        _name = State(initialValue: favorite.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("收藏名称") {
                    TextField("名称", text: $name)
                        .accessibilityIdentifier("favorite.renameField")
                    Button("保存名称") {
                        if favorites.rename(favorite, name: name) { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("favorite.saveName")
                }
                if let error = favorites.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("修改收藏名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
