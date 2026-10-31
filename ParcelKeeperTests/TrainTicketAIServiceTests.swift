import XCTest
@testable import ParcelKeeper

final class TrainTicketAIServiceTests: XCTestCase {
    var service: AIService!
    var network: AIServiceTests.Network!
    var defaults: UserDefaults!
    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        network = AIServiceTests.Network()
        service = AIService(defaults: defaults, keys: AIServiceTests.Keys(), network: network)
        let config = AIConfiguration(name: "test", baseURL: "https://example.invalid/v1", models: ["a", "b"], defaultModel: "a", fallbackModels: ["b"], enabled: true)
        try service.saveConfiguration(config, privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config.baseURL)
    }
    func fields() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(TrainTicketRecognition.parse(TrainTicketRecognitionTests.labeled)))
    }
    func response(_ fields: [String: String]) throws -> String {
        let content = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        return String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), encoding: .utf8)!
    }
    func testIndependentEditablePromptValidationReset() throws {
        try service.savePickupPrompt("取件提示")
        try service.saveTrainTicketPrompt("火车提示")
        XCTAssertEqual(service.loadTrainTicketPrompt(), "火车提示")
        for invalid in ["", " \n", String(repeating: "字", count: 12001)] { XCTAssertThrowsError(try service.saveTrainTicketPrompt(invalid)) }
        try service.saveTrainTicketPrompt(String(repeating: "字", count: 12000))
        service.resetTrainTicketPrompt()
        XCTAssertEqual(service.loadTrainTicketPrompt(), AIService.defaultTrainTicketPrompt)
        XCTAssertEqual(service.loadPickupPrompt(), "取件提示")
    }
    func testOriginalTextAndSeparateContractAndFallbackSnapshot() async throws {
        try service.saveTrainTicketPrompt("语义自定义")
        network.responses = [(503, ""), (200, try response(fields()))]
        network.onRequest = { try self.service.saveTrainTicketPrompt("下次使用") }
        let f = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled)
        XCTAssertEqual(f.trainNumber, "G311")
        for request in network.requests {
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages.count, 3)
            XCTAssertEqual(messages[0]["content"], "语义自定义")
            XCTAssertTrue(messages[1]["content"]!.contains("arrivalDate"))
            XCTAssertTrue(messages[1]["content"]!.contains("不可信"))
            XCTAssertEqual(messages[2]["content"], TrainTicketRecognitionTests.labeled)
        }
    }
    func testAIUnderstandsUnlabeledProseWithoutLocalReparse() async throws {
        let raw = "姜**的行程：2026年05月01日坐G311，11:05离开北京西，2026-05-01的21:08到南宁东；02车05A号二等座，检票口6B。"
        XCTAssertThrowsError(try TrainTicketRecognition.parse(raw))
        network.responses = [(200, try response(fields()))]
        let result = try await service.extractTrainTicket(raw)
        XCTAssertEqual(result.trainNumber, "G311")
        XCTAssertEqual(result.departureStation, "北京西")
    }
    func testHallucinatedYearAndFieldsRejected() async throws {
        for (key, value) in [("departureDate", "2027-05-01"), ("trainNumber", "G999"), ("departureStation", "上海"), ("seat", "06B"), ("passenger", "张三")] {
            var object = try fields(); object[key] = value
            network.responses = Array(repeating: (200, try response(object)), count: 2)
            do { _ = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled); XCTFail(key) }
            catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("\(error)") } }
        }
    }
    func testOrderYearCannotCompleteTravelYear() async throws {
        var object = try fields(); object["arrivalDate"] = ""; object["arrivalTime"] = ""
        let raw = "下单时间：2026-04-01 08:00\n5月01日周五\n北京西11:05\nG311\n南宁东21:08\n02车05A号二等座\n检票口6B\n乘车人姜**"
        network.responses = Array(repeating: (200, try response(object)), count: 2)
        do { _ = try await service.extractTrainTicket(raw); XCTFail("Do not invent year") }
        catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("\(error)") } }
        object["departureDate"] = ""
        network.responses = [(200, try response(object))]
        let draft = try await service.extractTrainTicket(raw)
        XCTAssertEqual(draft.departureDate, "")
    }
    func testAllFailuresNeverReturnLocalAndAuthStops() async throws {
        network.responses = [(503, ""), (503, "")]
        do { _ = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled); XCTFail() }
        catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("\(error)") } }
        network.requests = []; network.responses = [(401, "")]
        do { _ = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .authentication) }
        XCTAssertEqual(network.requests.count, 1)
    }
    func testAIDraftRetainsArrivalTimeWithoutInventingArrivalDate() async throws {
        var object = try fields(); object["arrivalDate"] = ""
        let raw = TrainTicketRecognitionTests.labeled.replacingOccurrences(of: "到达日期：2026-05-01\n", with: "")
        network.responses = [(200, try response(object))]
        let draft = try await service.extractTrainTicket(raw)
        XCTAssertEqual(draft.arrivalDate, "")
        XCTAssertEqual(draft.arrivalTime, "21:08")
        XCTAssertThrowsError(try draft.validated())
    }
    func testAIKeepsSleeperBerthText() async throws {
        var object = try fields()
        object["seat"] = "05号下铺"
        object["seatClass"] = "软卧"
        let raw = TrainTicketRecognitionTests.labeled
            .replacingOccurrences(of: "座位：05A", with: "座位：05号下铺")
            .replacingOccurrences(of: "席别：二等座", with: "席别：软卧")
        network.responses = [(200, try response(object))]
        let draft = try await service.extractTrainTicket(raw)
        XCTAssertEqual(draft.seat, "05号下铺")
        XCTAssertEqual(draft.seatClass, "软卧")
    }

    func testInlineOrderFieldsAreNotDateOrTimeEvidence() async throws {
        let raw = TrainTicketRecognitionTests.inline
        network.responses = [(200, try response(fields()))]
        let result = try await service.extractTrainTicket(raw)
        XCTAssertEqual(result, try TrainTicketRecognition.parse(TrainTicketRecognitionTests.labeled))
        for (key, value) in [("departureDate", "2026-04-25"), ("departureTime", "22:07"), ("arrivalDate", "2026-04-25"), ("arrivalTime", "22:07")] {
            var object = try fields(); object[key] = value
            network.responses = Array(repeating: (200, try response(object)), count: 2)
            do { _ = try await service.extractTrainTicket(raw); XCTFail(key) }
            catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("\(error)") } }
        }
        let missingYear = raw.replacingOccurrences(of: "2026-05-01", with: "5月1日")
        var object = try fields(); object["arrivalDate"] = ""; object["departureDate"] = "2026-05-01"
        network.responses = Array(repeating: (200, try response(object)), count: 2)
        do { _ = try await service.extractTrainTicket(missingYear); XCTFail("Do not borrow order year") }
        catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("\(error)") } }
    }

    func testPassengerListsRejectedBeforeNetworkAndEnglishNameAccepted() async throws {
        for name in ["张三 李四", "张三,李四", "张三，李四", "张三、李四"] {
            network.requests = []
            do { _ = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled.replacingOccurrences(of: "姜**", with: name)); XCTFail(name) }
            catch { guard case TrainTicketRecognitionError.ambiguous = error else { return XCTFail("\(error)") } }
            XCTAssertTrue(network.requests.isEmpty)
        }
        var object = try fields(); object["passenger"] = "John Smith"
        network.responses = [(200, try response(object))]
        let result = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled.replacingOccurrences(of: "姜**", with: "John Smith"))
        XCTAssertEqual(result.passenger, "John Smith")
        object["passenger"] = "张三 李四"
        let raw = TrainTicketRecognitionTests.labeled.replacingOccurrences(of: "乘车人：姜**", with: "张三 李四")
        network.responses = Array(repeating: (200, try response(object)), count: 2)
        do { _ = try await service.extractTrainTicket(raw); XCTFail("Multi-name AI field") }
        catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("\(error)") } }
    }

    func testCancellationDoesNotFallback() async throws {
        network.error = URLError(.cancelled)
        do { _ = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .cancelled) }
        XCTAssertEqual(network.requests.count, 1)
    }
    func testMultiTicketResponseCannotSelectOne() async throws {
        network.responses = Array(repeating: (200, try response(fields())), count: 2)
        do { _ = try await service.extractTrainTicket(TrainTicketRecognitionTests.labeled + "\nD123 乘车人：张三"); XCTFail() }
        catch { }
    }
}
