import SwiftUI

struct SelectedLocationCard: View {
    let selection: LocationSelection
    @ObservedObject var favorites: FavoriteLocationsStore
    let isResolvingAddress: Bool
    let isApplying: Bool
    let onUse: (LocationSelection) -> Void

    private var isSaved: Bool { favorites.contains(selection.coordinateWGS84) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(selection.name, systemImage: "mappin.circle.fill")
                .font(.headline).lineLimit(1)
            if let address = selection.address, !address.isEmpty {
                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if isResolvingAddress {
                Text("正在识别地址，也可直接收藏")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(selection.coordinateText).font(.caption).monospacedDigit()
            HStack {
                Button {
                    _ = favorites.add(selection)
                } label: {
                    Label(isSaved ? "已收藏" : "收藏", systemImage: isSaved ? "star.fill" : "star")
                }
                .buttonStyle(.bordered)
                .disabled(isSaved)
                .accessibilityIdentifier("selection.saveFavorite")
                Text("\(selection.accuracy, specifier: "%.1f") 米")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("使用此位置") { onUse(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
                    .accessibilityIdentifier("selection.use")
            }
            if let error = favorites.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
