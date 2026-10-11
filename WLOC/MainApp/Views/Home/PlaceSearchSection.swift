import SwiftUI

struct PlaceSearchSection: View {
    @ObservedObject var store: PlaceSearchStore
    var selectionHint = "选择地点，可收藏或继续长按地图选点"
    let onSelect: (PlaceSearchResult) -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("输入地点名称，例如武汉火车站", text: $store.query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("placeSearch.query")
                    .onSubmit { search() }
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("清空地点搜索")
                }
                Button(action: search) {
                    if store.isSearching {
                        ProgressView()
                    } else {
                        Text("搜索")
                    }
                }
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || store.isSearching)
                .accessibilityLabel(store.isSearching ? "正在搜索地点" : "搜索地点")
                .accessibilityIdentifier("placeSearch.search")
            }

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if store.hasSearched && !store.isSearching && store.results.isEmpty {
                Text("未找到地点，请尝试加上城市名或更换关键词")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.results) { result in
                Button {
                    isSearchFocused = false
                    onSelect(result)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name)
                                .foregroundStyle(.primary)
                            if !result.address.isEmpty {
                                Text(result.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .accessibilityHint(selectionHint)
                .accessibilityIdentifier("placeSearch.result")
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func search() {
        isSearchFocused = false
        Task { await store.search() }
    }
}
