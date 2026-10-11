import Combine
import Foundation

@MainActor
final class PlaceSearchStore: ObservableObject {
    @Published var query = "" {
        didSet {
            if query != oldValue {
                cancelAndClear()
            }
        }
    }
    @Published private(set) var results: [PlaceSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var errorMessage: String?

    private let service: any PlaceSearching
    private var requestID = UUID()

    init(service: any PlaceSearching) {
        self.service = service
    }

    convenience init() {
        self.init(service: MapKitPlaceSearchService())
    }

    func search() async {
        cancelAndClear()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        let currentRequestID = requestID
        isSearching = true
        hasSearched = true
        defer {
            if currentRequestID == requestID {
                isSearching = false
                if Task.isCancelled {
                    hasSearched = false
                }
            }
        }
        do {
            let found = try await service.search(query: trimmedQuery)
            guard currentRequestID == requestID, !Task.isCancelled else { return }
            results = found.filter { $0.mapCoordinate.isValid }
        } catch {
            guard currentRequestID == requestID, !Task.isCancelled else { return }
            if error is CancellationError {
                hasSearched = false
                return
            }
            errorMessage = "地点搜索失败，请检查网络后重试：\(error.localizedDescription)"
        }
    }

    func cancelAndClear() {
        requestID = UUID()
        service.cancel()
        results = []
        isSearching = false
        hasSearched = false
        errorMessage = nil
    }
}
