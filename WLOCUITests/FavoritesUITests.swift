import XCTest

@MainActor
final class FavoritesUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launchFresh() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["WLOC_UI_TEST_SESSION"] = UUID().uuidString
        app.launchEnvironment["WLOC_UI_TEST_RESET"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["收藏"].waitForExistence(timeout: 15))
    }

    private func fill(_ identifier: String, with text: String) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func finishKeyboard() {
        let done = app.buttons["完成"].firstMatch
        if done.exists && done.isHittable { done.tap() }
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func openCoordinates() {
        app.tabBars.buttons["收藏"].tap()
        app.buttons["favorites.add.number"].tap()
        XCTAssertTrue(app.textFields["favorite.longitude"].waitForExistence(timeout: 5))
    }

    private func addCoordinates(name: String = "Coordinate favorite") {
        openCoordinates()
        fill("favorite.longitude", with: "115.123456")
        fill("favorite.latitude", with: "31.234567")
        fill("favorite.accuracy", with: "12.5")
        fill("favorite.newName", with: name)
        finishKeyboard()
        let save = app.buttons["favorite.saveCoordinates"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testCoordinateFavoritePersistsAndAppliesOnlyOnExplicitUse() {
        launchFresh()
        let current = app.staticTexts["current.longitude"]
        reveal(current)
        let original = current.label
        addCoordinates()
        app.tabBars.buttons["首页"].tap()
        reveal(current)
        XCTAssertEqual(current.label, original, "Adding a favorite must not change the active test location")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "WLOC_UI_TEST_RESET")
        app.launch()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["Coordinate favorite"].waitForExistence(timeout: 5))
        app.buttons["favorite.use"].firstMatch.tap()
        reveal(current)
        XCTAssertEqual(current.label, "115.123456°")
        XCTAssertEqual(app.staticTexts["current.accuracy"].label, "12.5 米")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMapSelectionCanBeSavedWithoutAlertOrLeavingApp() {
        launchFresh()
        app.tabBars.buttons["收藏"].tap()
        app.buttons["favorites.add.map"].tap()
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        // Avoid the current-location annotation at the center and the zoom controls.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1)
        XCTAssertTrue(app.staticTexts["地图测试地点"].waitForExistence(timeout: 5))
        let save = app.buttons["selection.saveFavorite"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable, "One-tap favorite action must remain visible above the tab bar")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(app.alerts.count, 0)
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["地图测试地点"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "favorite.row").count, 1)
    }

    func testHomeSearchSelectsWithoutApplyingAndOffersPinnedActions() {
        launchFresh()
        let current = app.staticTexts["current.longitude"]
        let original = current.label
        fill("placeSearch.query", with: "Wuhan station")
        app.buttons["placeSearch.search"].tap()
        let result = app.buttons["placeSearch.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        let save = app.buttons["selection.saveFavorite"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        XCTAssertEqual(current.label, original)
        save.tap()
        XCTAssertFalse(save.isEnabled)
        let use = app.buttons["selection.use"]
        XCTAssertTrue(use.isHittable)
        use.tap()
        reveal(current)
        XCTAssertEqual(current.label, "114.424338°")
        XCTAssertEqual(app.staticTexts["current.accuracy"].label, "5.0 米")
        XCTAssertEqual(app.state, .runningForeground)
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["武汉站"].waitForExistence(timeout: 5))
    }

    func testSearchResultCanBeFavoritedDirectlyAndDuplicateIsNotAdded() {
        launchFresh()
        for _ in 0..<2 {
            app.tabBars.buttons["收藏"].tap()
            app.buttons["favorites.add.magnifyingglass"].tap()
            fill("placeSearch.query", with: "Wuhan station")
            app.buttons["placeSearch.search"].tap()
            let result = app.buttons["placeSearch.result"].firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10))
            result.tap()
            XCTAssertTrue(app.staticTexts["武汉站"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.otherElements.matching(identifier: "favorite.row").count, 1)
        XCTAssertTrue(app.staticTexts["湖北省武汉市洪山区"].exists)
    }

    func testRenameHasWorkingSaveButtonAndPersists() {
        launchFresh()
        addCoordinates()
        app.buttons["管理收藏：Coordinate favorite"].tap()
        app.buttons["修改名称"].tap()
        fill("favorite.renameField", with: "Renamed favorite")
        let save = app.buttons["favorite.saveName"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Renamed favorite"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "WLOC_UI_TEST_RESET")
        app.launch()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["Renamed favorite"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["精度 12.5 米"].exists)
    }

    func testInvalidCoordinatesShowErrorAndCanBeCorrected() {
        launchFresh()
        openCoordinates()
        fill("favorite.longitude", with: "999")
        fill("favorite.latitude", with: "30")
        finishKeyboard()
        app.buttons["favorite.saveCoordinates"].tap()
        XCTAssertTrue(app.staticTexts["favorite.validationError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["favorite.longitude"].exists)
        fill("favorite.longitude", with: "114")
        fill("favorite.newName", with: "Corrected favorite")
        finishKeyboard()
        app.buttons["favorite.saveCoordinates"].tap()
        XCTAssertTrue(app.staticTexts["Corrected favorite"].waitForExistence(timeout: 5))
    }

    func testDeletingFavoritePersistsAfterRelaunch() {
        launchFresh()
        addCoordinates()
        app.buttons["管理收藏：Coordinate favorite"].tap()
        app.buttons["删除收藏"].tap()
        app.buttons["删除收藏"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["还没有收藏"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "WLOC_UI_TEST_RESET")
        app.launch()
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.staticTexts["还没有收藏"].waitForExistence(timeout: 5))
    }
}
