import XCTest
import WebKit
@testable import ParcelKeeper

/// Offline WebKit engine + production capture + native parser; not shopping-account acceptance.
@MainActor
final class JDReferenceWebKitTests: XCTestCase {
    private final class Receiver: NSObject, WKScriptMessageHandler {
        let ready: XCTestExpectation
        var value: [String: Any]?
        init(_ ready: XCTestExpectation) { self.ready = ready }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard value == nil, let body = message.body as? [String: Any], body["kind"] as? String == "orders" else { return }
            value = body
            ready.fulfill()
        }
    }
    private func capture(wrapped: Bool, requestBody: String) async throws -> [JDPageParser.Order] {
        let root: [String: Any] = ["body": ["orderList": [["orderId": "123456789012", "wareInfoList": [["wareName": "合成商品"]], "orderStatusInfo": ["orderStatusName": "已完成"]]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let plain = String(decoding: data, as: UTF8.self)
        let raw = wrapped ? String(decoding: try JSONEncoder().encode(plain), as: UTF8.self) : plain
        let jsString = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        let bodyString = String(decoding: try JSONEncoder().encode(requestBody), as: UTF8.self)
        let ready = expectation(description: "Production capture receives actual WK message")
        let receiver = Receiver(ready)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(receiver, name: "jdCapture")
        // No external requests: install the synthetic response before production wrapper.
        let transport = "window.fetch=function(){return Promise.resolve({status:200,url:'https://api.m.jd.com/api',clone:function(){return {text:function(){return Promise.resolve(\(jsString));}};}});};"
        config.userContentController.addUserScript(WKUserScript(source: transport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: JDPageScript.capture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        defer {
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "jdCapture")
            config.userContentController.removeAllUserScripts()
        }
        web.loadHTMLString("<html><body><script>window.fetch('https://api.m.jd.com/api?functionId=order_list_m&body='+encodeURIComponent(\(bodyString)));</script></body></html>", baseURL: MallPlatform.jd.ordersURL)
        await fulfillment(of: [ready], timeout: 10)
        let value = try XCTUnwrap(receiver.value)
        return try JDPageParser.orders(value)
    }
    func testStringWrappedCurrentListInWebKitDoesNotNeedDOMCards() async throws {
        let rows = try await capture(wrapped: true, requestBody: "null")
        XCTAssertEqual(rows.map(\.id), ["123456789012"])
        XCTAssertNil(rows.first?.submittedAt)
    }
    func testRestoredNonFirstPageRemainsRecognizedInWebKit() async throws {
        let rows = try await capture(wrapped: false, requestBody: "{\"page\":3,\"pageSize\":10,\"curTab\":\"all\"}")
        XCTAssertEqual(rows.map(\.id), ["123456789012"])
    }
}
