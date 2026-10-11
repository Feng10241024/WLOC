import Foundation
import Testing
#if canImport(WLOCLocationLibrary)
@testable import WLOCLocationLibrary
#else
@testable import WLOC
#endif

@MainActor
struct PlaceSearchStoreTests {
    @Test func emptyQueryDoesNotIssueNetworkRequest() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = " \n "
        await store.search()
        #expect(service.requests.isEmpty)
        #expect(!store.isSearching)
        #expect(!store.hasSearched)
    }

    @Test func searchTrimsQueryAndKeepsReturnedMapCoordinatesUnchanged() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "  武汉火车站\n"
        let task = Task { await store.search() }
        await service.waitForRequestCount(1)
        #expect(store.isSearching)
        #expect(service.requests[0].query == "武汉火车站")
        let result = makeResult("武汉火车站", latitude: 30.61, longitude: 114.42)
        service.complete(0, with: .success([result]))
        await task.value
        #expect(store.results == [result])
        #expect(!store.isSearching)
        #expect(store.hasSearched)
        #expect(store.errorMessage == nil)
    }

    @Test func invalidSearchCoordinatesAreExcluded() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "车站"
        let task = Task { await store.search() }
        await service.waitForRequestCount(1)
        let valid = makeResult("有效")
        service.complete(0, with: .success([valid, makeResult("无效", latitude: .nan)]))
        await task.value
        #expect(store.results == [valid])
    }

    @Test func emptyResponseCanBeDistinguishedFromNotYetSearching() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "不存在的地点"
        let task = Task { await store.search() }
        await service.waitForRequestCount(1)
        service.complete(0, with: .success([]))
        await task.value
        #expect(store.hasSearched && !store.isSearching && store.results.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func retryClearsPreviousNetworkError() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "车站"
        let failedTask = Task { await store.search() }
        await service.waitForRequestCount(1)
        service.complete(0, with: .failure(URLError(.notConnectedToInternet)))
        await failedTask.value
        #expect(store.errorMessage?.contains("地点搜索失败") == true)
        #expect(!store.isSearching)
        let retry = Task { await store.search() }
        await service.waitForRequestCount(2)
        #expect(store.errorMessage == nil)
        let result = makeResult("车站")
        service.complete(1, with: .success([result]))
        await retry.value
        #expect(store.results == [result])
        #expect(store.errorMessage == nil)
    }

    @Test func olderResponseCannotOverwriteANewerSearch() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "旧查询"
        let old = Task { await store.search() }
        await service.waitForRequestCount(1)
        store.query = "新查询"
        let new = Task { await store.search() }
        await service.waitForRequestCount(2)
        let newResult = makeResult("新地点")
        service.complete(1, with: .success([newResult]))
        await new.value
        service.complete(0, with: .success([makeResult("旧地点")]))
        await old.value
        #expect(store.results == [newResult])
        #expect(!store.isSearching)
    }

    @Test func oldFailureCannotClearTheNewSearchLoadingState() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "旧查询"
        let old = Task { await store.search() }
        await service.waitForRequestCount(1)
        store.query = "新查询"
        let new = Task { await store.search() }
        await service.waitForRequestCount(2)
        service.complete(0, with: .failure(URLError(.cancelled)))
        await old.value
        #expect(store.isSearching)
        #expect(store.errorMessage == nil)
        service.complete(1, with: .success([]))
        await new.value
        #expect(!store.isSearching)
    }

    @Test func clearingQueryRejectsResultsAlreadyInFlight() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "车站"
        let task = Task { await store.search() }
        await service.waitForRequestCount(1)
        store.query = ""
        service.complete(0, with: .success([makeResult("过期地点")]))
        await task.value
        #expect(store.results.isEmpty)
        #expect(!store.isSearching)
        #expect(!store.hasSearched)
        #expect(store.errorMessage == nil)
        #expect(service.cancelCount >= 2)
    }

    @Test func cancellingCallerDoesNotPublishResultsOrShowNoMatches() async {
        let service = ControlledPlaceSearchService()
        let store = PlaceSearchStore(service: service)
        store.query = "车站"
        let task = Task { await store.search() }
        await service.waitForRequestCount(1)
        task.cancel()
        service.complete(0, with: .success([makeResult("车站")]))
        await task.value
        #expect(store.results.isEmpty)
        #expect(!store.isSearching)
        #expect(!store.hasSearched)
        #expect(store.errorMessage == nil)
    }

    private func makeResult(
        _ name: String,
        latitude: Double = 30.6,
        longitude: Double = 114.4
    ) -> PlaceSearchResult {
        PlaceSearchResult(
            name: name,
            address: "测试用地址",
            mapCoordinate: LocationCoordinate(latitude: latitude, longitude: longitude)
        )
    }
}

@MainActor
private final class ControlledPlaceSearchService: PlaceSearching {
    struct Request {
        let query: String
        let continuation: CheckedContinuation<[PlaceSearchResult], any Error>
    }
    private(set) var requests: [Request] = []
    private(set) var cancelCount = 0
    private var requestWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func search(query: String) async throws -> [PlaceSearchResult] {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(query: query, continuation: continuation))
            if let waiter = requestWaiter, requests.count >= waiter.count {
                requestWaiter = nil
                waiter.continuation.resume()
            }
        }
    }

    func cancel() { cancelCount += 1 }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiter = (count, continuation)
        }
    }

    func complete(_ index: Int, with result: Result<[PlaceSearchResult], any Error>) {
        requests[index].continuation.resume(with: result)
    }
}
