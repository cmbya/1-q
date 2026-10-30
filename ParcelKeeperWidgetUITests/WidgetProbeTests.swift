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
    // Each test prepares its own app launch and gallery; neither requires
    // the other test to execute or pass.
    @MainActor private func openProbeGallery() throws {
        let app = XCUIApplication()
        app.terminate()
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
    }

    @MainActor private func selectGalleryWidget(named name: String) throws {
        let title = home.staticTexts[name].firstMatch
        // Bound the gallery search; missing registration must fail.
        for _ in 0..<40 {
            if title.waitForExistence(timeout: 1) { return }
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: home.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)))
        }
        capture("gallery-widget-missing")
        throw NSError(domain: "WidgetProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Widget absent from diagnostic gallery: \(name)"])
    }

    @MainActor func testMinimalConfiguredWidget() throws {
        continueAfterFailure = false
        try openProbeGallery()
        try selectGalleryWidget(named: "Minimal configuration probe")
        capture("minimal-gallery")
        try tap(home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch)
        sleep(3)
        if home.buttons["Done"].exists { home.buttons["Done"].tap() }
        sleep(10)
        capture("minimal-placed")
        let ok = home.staticTexts["MINIMAL-CONFIG-OK"].firstMatch
        // MinimalProvider.snapshot and .timeline return the same output.
        // This checks rendering only, not which callback ran.
        XCTAssertTrue(ok.waitForExistence(timeout: 30), "Minimal widget did not render its provider output; inspect screenshot")
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
    }

    // Independent production load smoke, not a legacy AppIntent prerequisite.
    @MainActor func testProductionSlotALoadSmoke() throws {
        continueAfterFailure = false
        try openProbeGallery()
        try selectGalleryWidget(named: "取件组件 A")
        capture("production-slot-A-gallery")
        try tap(home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch)
        if home.buttons["Done"].waitForExistence(timeout: 5) { home.buttons["Done"].tap() }
        // Fresh CI may have no selected/authorized shared group. Both messages
        // originate in SlotProvider.load(), unlike placeholder(in:).
        // BOTH getSnapshot and getTimeline call load(): the labels prove only
        // rendered load output, NOT which callback ran or shared-data success.
        let unbound = home.staticTexts["请打开 App → 设置 → 桌面组件，绑定此组件的分组"].firstMatch
        let unavailable = home.staticTexts["读取失败，请打开 App 检查共享数据或重新绑定分组"].firstMatch
        let loaded = unbound.waitForExistence(timeout: 30) || unavailable.waitForExistence(timeout: 5)
        XCTAssertTrue(loaded, "Production slot A did not render an expected load result on the fresh simulator (snapshot/timeline not distinguished)")
        if unavailable.exists { print("PROBE slot A load returned storage-unavailable; callback origin and shared-data success NOT verified") }
        capture("production-slot-A-placed")
    }
}
