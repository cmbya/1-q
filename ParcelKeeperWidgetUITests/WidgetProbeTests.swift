import XCTest

// Opt-in smoke probe only; English SpringBoard labels and fresh-simulator
// coordinates are environment-dependent. This does NOT cover slots B–J,
// successful shared-data reads, binding/rebinding/deletion, completion errors,
// privacy masking, or all widget families. Do not treat it as full UI acceptance.
// Not launched or verified by the Linux source-review workflow.
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
        guard tile.waitForExistence(timeout: 15) else {
            capture("tile-AX-unavailable")
            XCTFail("Cannot locate placed widget; configuration probe was not executed")
            return
        }
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
        // Separate smoke check of a real A–J slot. D3 is a legacy AppIntent
        // diagnostic and is NOT evidence that production SlotProvider runs.
        try probeProductionSlotA()
    }

    @MainActor private func probeProductionSlotA() throws {
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.87)).press(forDuration: 2)
        if home.buttons["Edit"].exists {
            try tap(home.buttons["Edit"])
            try tap(home.buttons["Add Widget"])
        } else {
            try tap(home.buttons["Add"])
        }
        let search = home.searchFields.firstMatch
        try tap(search)
        search.typeText("ParcelKeeper Probe")
        try tap(home.cells.matching(NSPredicate(format: "label CONTAINS %@", "ParcelKeeper Probe")).firstMatch)
        let title = home.staticTexts["取件组件 A"].firstMatch
        // Bound the gallery search; missing production registration must fail.
        for _ in 0..<40 {
            if title.waitForExistence(timeout: 1) { break }
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: home.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)))
        }
        guard title.exists else {
            capture("production-slot-A-missing")
            XCTFail("Production SlotWidget A is absent from diagnostic gallery")
            return
        }
        capture("production-slot-A-gallery")
        try tap(home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch)
        if home.buttons["Done"].waitForExistence(timeout: 5) { home.buttons["Done"].tap() }
        // Fresh CI may have no selected/authorized shared group. Both messages
        // originate in SlotProvider.load(), unlike the gallery placeholder.
        // This proves a production timeline, NOT successful shared-data access.
        let unbound = home.staticTexts["请打开 App → 设置 → 桌面组件，绑定此组件的分组"].firstMatch
        let unavailable = home.staticTexts["读取失败，请打开 App 检查共享数据或重新绑定分组"].firstMatch
        let delivered = unbound.waitForExistence(timeout: 30) || unavailable.waitForExistence(timeout: 5)
        XCTAssertTrue(delivered, "Production slot A did not deliver its load result on the fresh simulator")
        if unavailable.exists { print("PROBE slot A timeline returned storage-unavailable; shared-data success NOT verified") }
        capture("production-slot-A-placed")
    }
}
