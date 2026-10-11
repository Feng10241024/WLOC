import SwiftUI

struct MapZoomButtons: View {
    let zoomIn: (MapZoomCommand.Mode) -> Void
    let zoomOut: (MapZoomCommand.Mode) -> Void
    let centerOnTestLocation: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            MapZoomButton(
                systemImage: "plus",
                accessibilityLabel: "放大地图",
                action: zoomIn
            )
            MapZoomButton(
                systemImage: "minus",
                accessibilityLabel: "缩小地图",
                action: zoomOut
            )
            MapCenterButton(action: centerOnTestLocation)
        }
    }
}

private struct MapCenterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .accessibilityLabel("将测试位置移到地图中心")
    }
}

private struct MapZoomButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: (MapZoomCommand.Mode) -> Void

    @State private var repeatTask: Task<Void, Never>?
    @State private var didRepeatDuringCurrentPress = false

    var body: some View {
        Button {
            if didRepeatDuringCurrentPress {
                didRepeatDuringCurrentPress = false
            } else {
                action(.singleTap)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .accessibilityLabel(accessibilityLabel)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startRepeatingIfNeeded() }
                .onEnded { _ in stopRepeating() }
        )
        .onDisappear(perform: stopRepeating)
    }

    private func startRepeatingIfNeeded() {
        guard repeatTask == nil else {
            return
        }
        didRepeatDuringCurrentPress = false
        repeatTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(220))
                while !Task.isCancelled {
                    didRepeatDuringCurrentPress = true
                    action(.continuous)
                    try await Task.sleep(for: .milliseconds(65))
                }
            } catch {
                // Releasing the button cancels the repeating task.
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
