import XCTest
@testable import WispCore
@testable import WispMac

/// Fake NIM: answers per model id with a scripted list of responses (one per request, last one repeats).
final class StubNIM: URLProtocol, @unchecked Sendable {
    enum Reply { case busy, garbled, answer(String, delay: Double), http(Int) }
    nonisolated(unsafe) static var script: [String: [Reply]] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()
    nonisolated(unsafe) static var lastAuthorization: String??

    static func next(for model: String) -> Reply {
        lock.withLock {
            calls.append(model)
            var list = script[model] ?? [.http(404)]
            let reply = list.count > 1 ? list.removeFirst() : list[0]
            script[model] = list
            return reply
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = data
        }
        Self.lock.withLock { Self.lastAuthorization = .some(request.value(forHTTPHeaderField: "Authorization")) }
        let model = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])?["model"] as? String ?? ""
        let reply = Self.next(for: model)
        func send(_ code: Int, _ text: String, after delay: Double = 0) {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        func sse(_ content: String) -> String {
            let chunk = ["choices": [["delta": ["content": content]]]]
            return "data: " + String(data: try! JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)! + "\n\ndata: [DONE]\n\n"
        }
        switch reply {
        case .busy: send(200, "data: {\"error\":{\"message\":\"ResourceExhausted: Worker local total request limit reached (16/16)\",\"code\":500}}\n\n", after: 0.05)
        case .garbled: send(200, sse("!!!!!!!!!!!!!!!!"), after: 0.05)
        case .answer(let text, let delay): send(200, sse(text), after: delay)
        case .http(let code): send(code, "{}", after: 0.05)
        }
    }
}

final class AssistantEngineTests: XCTestCase {
    let primary = VisionModelInfo(id: "p", displayName: "P")
    let fallback = VisionModelInfo(id: "f", displayName: "F")

    func run(_ script: [String: [StubNIM.Reply]]) async -> (events: [AssistantEvent], timing: VisionTiming?, error: VisionError?) {
        StubNIM.lock.withLock { StubNIM.script = script; StubNIM.calls = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubNIM.self]
        let client = VisionClient(baseURL: URL(string: "https://stub.invalid/v1")!, policy: ConsentPolicyGate(disclosureAccepted: { true }),
                                  apiKey: { "test" }, sessionConfiguration: config)
        let engine = AssistantEngine(client: client)
        var events: [AssistantEvent] = [], timing: VisionTiming?, error: VisionError?
        let facts = TurnFacts(imageSize: PixelSize(width: 100, height: 100), cursorInImage: nil, frontmostAppName: nil, question: "q")
        for await output in engine.ask(jpegs: [Data([0xFF])], facts: facts, models: [primary, fallback], frontmostBundleID: nil,
                                       firstTokenTimeout: 5, totalTimeout: 8) {
            switch output {
            case .event(let e, _): events.append(e)
            case .finished(let t, let e): timing = t; error = e
            }
        }
        return (events, timing, error)
    }

    func testPrimaryAnswers() async {
        let r = await run(["p": [.answer("SAY: from p.\n", delay: 0)], "f": [.answer("SAY: from f.\n", delay: 0)]])
        XCTAssertEqual(r.events, [.say("from p.")])
        XCTAssertEqual(r.timing?.modelID, "p")
        XCTAssertEqual(r.timing?.attempts, 1)
        XCTAssertNil(r.error)
    }

    func testBusyHedgesAndFastestWins() async {
        // Primary busy, then its retry is slow; the fallback answers first and owns the output.
        let r = await run(["p": [.busy, .answer("SAY: from p.\n", delay: 1.0)], "f": [.answer("SAY: from f.\n", delay: 0.1)]])
        XCTAssertEqual(r.events, [.say("from f.")])
        XCTAssertEqual(r.timing?.modelID, "f")
        XCTAssertEqual(r.timing?.attempts, 3)
        XCTAssertNil(r.error)
    }

    func testGarbledHedgesAndPrimaryRetryWins() async {
        let r = await run(["p": [.garbled, .answer("SAY: from p.\n", delay: 0.05)], "f": [.answer("SAY: from f.\n", delay: 0.8)]])
        XCTAssertEqual(r.events, [.say("from p.")], "only the winner's words are spoken")
        XCTAssertEqual(r.timing?.modelID, "p")
    }

    func testHardErrorFallsBackWithoutHedging() async {
        let r = await run(["p": [.http(502)], "f": [.answer("SAY: from f.\n", delay: 0)]])
        XCTAssertEqual(r.events, [.say("from f.")])
        XCTAssertEqual(r.timing?.attempts, 2)
        XCTAssertEqual(StubNIM.lock.withLock { StubNIM.calls }, ["p", "f"])
    }

    func testTopicThenGlitchStillFallsBack() async {
        // A lane that only got as far as its TOPIC line before glitching must not own the answer.
        let r = await run(["p": [.answer("TOPIC: screen\n!!!!!!!!!!!!!!!!!!!!!!!!", delay: 0)], "f": [.answer("TOPIC: other\nSAY: from f.\n", delay: 0.05)]])
        XCTAssertEqual(r.events, [.topic(.other), .say("from f.")])
        XCTAssertEqual(r.timing?.modelID, "f")
    }

    func testTopicOnlyReplyIsNotAnAnswer() async {
        let r = await run(["p": [.answer("TOPIC: screen\n", delay: 0)], "f": [.answer("SAY: from f.\n", delay: 0)]])
        XCTAssertEqual(r.events, [.say("from f.")])
    }

    func testEverythingBusyReportsBusy() async {
        let r = await run(["p": [.busy], "f": [.busy]])
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertEqual(r.error?.isBusy, true)
    }

    func testMissingKeyDoesNotFallBack() async {
        StubNIM.lock.withLock { StubNIM.calls = [] }
        let client = VisionClient(baseURL: URL(string: "https://stub.invalid/v1")!, policy: ConsentPolicyGate(disclosureAccepted: { true }),
                                  apiKey: { nil })
        let engine = AssistantEngine(client: client)
        let facts = TurnFacts(imageSize: PixelSize(width: 1, height: 1), cursorInImage: nil, frontmostAppName: nil, question: "q")
        var error: VisionError?
        for await output in engine.ask(jpegs: [Data()], facts: facts, models: [primary, fallback], frontmostBundleID: nil,
                                       firstTokenTimeout: 2, totalTimeout: 3) {
            if case .finished(let t, let e) = output { error = e; XCTAssertEqual(t.attempts, 1) }
        }
        XCTAssertEqual(error, .missingAPIKey)
    }
}

final class KeylessProviderTests: XCTestCase {
    private func client(key: String?, requiresKey: Bool) -> VisionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubNIM.self]
        return VisionClient(baseURL: URL(string: "https://stub.invalid/v1")!, policy: ConsentPolicyGate(disclosureAccepted: { true }),
                            apiKey: { key }, requiresKey: requiresKey, sessionConfiguration: config)
    }

    private func ask(_ client: VisionClient) async throws -> String {
        let request = VisionRequest(model: VisionModelInfo(id: "local-model", displayName: "L"), systemPrompt: "s", userText: "u",
                                    jpegs: [Data([0xFF])], maxTokens: 10, temperature: 0)
        var text = ""
        for try await chunk in client.stream(request, frontmostBundleID: nil) { text += chunk }
        return text
    }

    func testCustomServerWithoutKeySendsNoAuthorization() async throws {
        StubNIM.lock.withLock { StubNIM.script = ["local-model": [.answer("SAY: hi", delay: 0)]]; StubNIM.lastAuthorization = nil }
        let text = try await ask(client(key: nil, requiresKey: false))
        XCTAssertEqual(text, "SAY: hi")
        XCTAssertEqual(StubNIM.lock.withLock { StubNIM.lastAuthorization }, .some(nil))
    }

    func testNvidiaStillNeedsAKey() async {
        do {
            _ = try await ask(client(key: nil, requiresKey: true))
            XCTFail("expected missing key")
        } catch {
            XCTAssertEqual(error as? VisionError, .missingAPIKey)
        }
    }

    func testCustomModelUsesChosenPositionFormat() {
        var vision = VisionSettings()
        vision.modelID = "my-local-vision-model"
        vision.customCoordinateSpace = .normalized1000
        XCTAssertEqual(vision.modelInfo.coordinateSpace, .normalized1000)
        vision.modelID = VisionSettings.defaultModelID
        XCTAssertEqual(vision.modelInfo.coordinateSpace, VisionModelCatalog.info(for: VisionSettings.defaultModelID).coordinateSpace)
    }
}
