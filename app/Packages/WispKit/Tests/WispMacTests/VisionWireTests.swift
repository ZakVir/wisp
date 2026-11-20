import XCTest
@testable import WispMac
import WispCore

final class VisionWireTests: XCTestCase {
    private let request = VisionRequest(model: VisionModelInfo(id: "claude-sonnet-5-5", displayName: "Claude"),
                                        systemPrompt: "SYS", userText: "USER", jpegs: [Data([1, 2, 3])])

    func testAnthropicRequestShape() throws {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let r = try VisionClient.makeURLRequest(request, endpoint: url, key: "k", wire: .anthropicMessages, timeout: 10)
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual((content.first?["source"] as? [String: Any])?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(content.last?["text"] as? String, "USER")
    }

    func testOpenAIRequestShape() throws {
        let r = try VisionClient.makeURLRequest(request, endpoint: URL(string: "https://x/v1/chat/completions")!, key: "k", wire: .openAIChat, timeout: 10)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(((body["messages"] as? [[String: Any]])?.first?["role"]) as? String, "system")
    }

    func testAnthropicStreamLines() throws {
        XCTAssertEqual(try VisionClient.parse(line: "event: content_block_delta", wire: .anthropicMessages), .skip)
        XCTAssertEqual(try VisionClient.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SAY: Hi"}}"#, wire: .anthropicMessages), .text("SAY: Hi"))
        XCTAssertEqual(try VisionClient.parse(line: #"data: {"type":"message_start","message":{}}"#, wire: .anthropicMessages), .skip)
        XCTAssertEqual(try VisionClient.parse(line: #"data: {"type":"message_stop"}"#, wire: .anthropicMessages), .done)
        XCTAssertThrowsError(try VisionClient.parse(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, wire: .anthropicMessages)) {
            XCTAssertEqual($0 as? VisionError, .http(429, "overloaded"))
        }
    }

    func testOpenAIStreamLines() throws {
        XCTAssertEqual(try VisionClient.parse(line: #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#, wire: .openAIChat), .text("Hello"))
        XCTAssertEqual(try VisionClient.parse(line: "data: [DONE]", wire: .openAIChat), .done)
    }
}
