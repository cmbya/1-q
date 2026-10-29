import XCTest

final class WidgetProbeTests: XCTestCase {
    private let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    @MainActor private func capture(_ name: String) {
        print("PROBE TREE \(name)\n\(home.debugDescription)")
        let image = XCTAttachment(screenshot: home.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    @MainActor private func tap(_ element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 15) else {
            capture("missing-element")
            throw NSError(domain: "WidgetProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing UI: \(element)"])
        }
        element.tap()
    }
    @MainActor func testMinimalConfiguredWidget() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        sleep(3)
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
        sleep(2)
        // Blank region on the fresh CI simulator, not an app icon.
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.87)).press(forDuration: 2)
        capture("jiggle")
        if home.buttons["Edit"].exists {
            try tap(home.buttons["Edit"])
            try tap(home.buttons["Add Widget"])
        } else {
            try tap(home.buttons["Add"])
        }
        let search = home.searchFields.firstMatch
        try tap(search)
        search.typeText("ParcelKeeper Probe")
        capture("search-results")
        let result = home.cells.matching(NSPredicate(format: "label CONTAINS %@", "ParcelKeeper Probe")).firstMatch
        try tap(result)
        sleep(3)
        capture("minimal-gallery")
        try tap(home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch)
        sleep(3)
        if home.buttons["Done"].exists { home.buttons["Done"].tap() }
        sleep(10)
        capture("minimal-placed")
        let ok = home.staticTexts["MINIMAL-CONFIG-OK"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 30), "Minimal widget did not deliver its timeline; inspect screenshot and chronod log")
        let tile = home.icons.matching(NSPredicate(format: "label == %@ AND value == 'Widget'", "ParcelKeeper Probe")).firstMatch
        guard tile.exists else { capture("tile-AX-unavailable"); return }
        tile.press(forDuration: 1.5)
        try tap(home.buttons["Edit Widget"])
        capture("edit-configuration")
        let field = home.textFields.firstMatch
        try tap(field)
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText("CONFIG-BETA")
        if home.buttons["Done"].exists { home.buttons["Done"].tap() }
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16)).tap()
        sleep(10)
        capture("configured-beta")
        XCTAssertTrue(home.staticTexts["CONFIG-BETA"].firstMatch.waitForExistence(timeout: 30), "Configured value did not reach the tile")
    }
}
