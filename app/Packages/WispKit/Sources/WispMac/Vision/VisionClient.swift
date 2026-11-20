import Foundation
import WispCore

/// One request to a vision model.
public struct VisionRequest: Sendable {
    public var model: VisionModelInfo
    public var systemPrompt: String
    public var userText: String
    /// One or more screenshots, in the order the prompt describes them.
    public var jpegs: [Data]
    public var maxTokens: Int = 400
    public var temperature: Double = 0.2

    public init(model: VisionModelInfo, systemPrompt: String, userText: String, jpegs: [Data], maxTokens: Int = 400, temperature: Double = 0.2) {
        self.model = model; self.systemPrompt = systemPrompt; self.userText = userText; self.jpegs = jpegs
        self.maxTokens = maxTokens; self.temperature = temperature
    }
}

public enum VisionError: Error, Equatable, Sendable {
    case missingAPIKey
    case blocked(String)
    case http(Int, String)
    case timeout
    /// The model produced garbage (e.g. runs of "!!!!"); retry with another model.
    case degenerateOutput
    case network(String)
    case cancelled

    /// Plain words for captions and speech.
    public var userMessage: String {
        switch self {
        case .missingAPIKey: return "I need a key for my AI first. Open Wisp Settings, choose AI, and paste it in."
        case .blocked(let m): return m
        case .http(let code, _) where code == 401 || code == 403: return "The AI service didn't accept your key. Open Wisp Settings, choose AI, and paste a new one."
        case .http(let code, _) where code == 404: return "The AI service doesn't know that model. Open Wisp Settings, choose AI, and check the model."
        case .http(let code, _) where code == 429: return "The AI service is busy right now. Try again in a moment."
        case .http: return "The AI service had a problem. Try again in a moment."
        case .timeout: return "That's taking too long. Try asking again."
        case .degenerateOutput: return "I got a garbled answer. Try asking again."
        case .network: return "I lost the connection. Check your internet and try again."
        case .cancelled: return ""
        }
    }

    /// Retry with another model only when another model could do better (not for a bad key or a blocked app).
    public var isRetryableWithAnotherModel: Bool {
        switch self {
        case .timeout, .degenerateOutput: return true
        case .http(let code, _): return code == 404 || code == 429 || code >= 500
        default: return false
        }
    }

    /// Short, content-free code for logs and timing files (never includes server response bodies).
    public var code: String {
        switch self {
        case .missingAPIKey: return "missing_key"
        case .blocked: return "blocked"
        case .http(let code, _): return "http_\(code)"
        case .timeout: return "timeout"
        case .degenerateOutput: return "degenerate"
        case .network: return "network"
        case .cancelled: return "cancelled"
        }
    }

    /// The service said it is overloaded or rate-limited (HTTP 429, or NIM's in-stream "ResourceExhausted").
    public var isBusy: Bool {
        if case .http(429, _) = self { return true }
        return false
    }
}

/// Streams a chat completion from an OpenAI-compatible endpoint (NVIDIA NIM) and yields text deltas.
/// Reasoning/"thinking" deltas are ignored; only answer content is passed on.
public final class VisionClient: Sendable {
    /// How requests and streamed answers are shaped: OpenAI's chat completions (NVIDIA, most servers) or
    /// Anthropic's Messages API (Claude).
    public enum Wire: Sendable { case openAIChat, anthropicMessages }

    public let baseURL: URL
    public let wire: Wire
    private let sessionConfiguration: URLSessionConfiguration
    private let policy: PolicyGate
    private let apiKey: @Sendable () -> String?
    private let requiresKey: Bool

    public init(baseURL: URL, policy: PolicyGate, apiKey: @escaping @Sendable () -> String? = { APIKeyStore.key(for: .nvidiaNIM) },
                requiresKey: Bool = true, wire: Wire = .openAIChat, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.wire = wire
        self.policy = policy
        self.apiKey = apiKey
        self.requiresKey = requiresKey
        self.sessionConfiguration = sessionConfiguration
    }

    /// Returns a stream of answer text chunks. Throws `VisionError`.
    /// - Parameters:
    ///   - firstTokenTimeout: seconds allowed until the first content token.
    ///   - totalTimeout: seconds allowed for the whole answer.
    public func stream(_ request: VisionRequest, frontmostBundleID: String?, firstTokenTimeout: Double = 15,
                       totalTimeout: Double = 40) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, frontmostBundleID: frontmostBundleID, firstTokenTimeout: firstTokenTimeout,
                                       totalTimeout: totalTimeout, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: VisionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps an error object sent inside the event stream; overload ("ResourceExhausted", limits) counts as 429.
    static func streamError(_ error: [String: Any]) -> VisionError {
        let message = error["message"] as? String ?? ""
        let busy = message.range(of: "ResourceExhausted|limit|overload|capacity", options: [.regularExpression, .caseInsensitive]) != nil
        let code = (error["code"] as? Int) ?? Int(error["code"] as? String ?? "") ?? 502
        return .http(busy ? 429 : (code >= 400 ? code : 502), String(message.prefix(200)))
    }

    private func run(_ request: VisionRequest, frontmostBundleID: String?, firstTokenTimeout: Double, totalTimeout: Double,
                     continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let key = apiKey() ?? ""
        if requiresKey && key.isEmpty { throw VisionError.missingAPIKey }
        let endpoint = baseURL.appendingPathComponent(wire == .anthropicMessages ? "messages" : "chat/completions")
        if case .deny(let message) = policy.evaluate(NetworkIntent(purpose: .visionRequest, host: endpoint.host ?? "",
                                                                   carriesUserContent: true, frontmostBundleID: frontmostBundleID)) {
            throw VisionError.blocked(message)
        }

        let urlRequest = try Self.makeURLRequest(request, endpoint: endpoint, key: key, wire: wire, timeout: totalTimeout)

        let gotContent = Flag()
        let deadlineHit = Flag()
        // A session per request: invalidating it is the only reliable way to abort a stalled stream
        // (cancelling an AsyncBytes iteration on a shared session did not stop it; observed a 595 s stall).
        let session = URLSession(configuration: self.sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let finalRequest = urlRequest
        // Two children race: the reader, and a deadline watcher (first answer token, then total time).
        // Reasoning tokens don't count as an answer, so a model stuck "thinking" still times out.
        // Cancelling the caller (barge-in) must abort the HTTP stream immediately: AsyncBytes iteration doesn't
        // reliably observe task cancellation, so tear the session down.
        try await withTaskCancellationHandler {
        do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                do {
                    (bytes, response) = try await session.bytes(for: finalRequest)
                } catch {
                    throw Self.mapNetwork(error)
                }
                guard let http = response as? HTTPURLResponse else { throw VisionError.network("no response") }
                guard http.statusCode == 200 else {
                    var snippet = ""
                    for try await line in bytes.lines { snippet += line; if snippet.count > 300 { break } }
                    // Anthropic says "overloaded" with 529: busy, like a 429.
                    throw VisionError.http(http.statusCode == 529 ? 429 : http.statusCode, String(snippet.prefix(300)))
                }
                var detector = DegenerateOutputDetector()
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let item = try Self.parse(line: line, wire: self.wire)
                        if item == .done { break }
                        guard case .text(let content) = item else { continue }
                        // Whitespace (some models send "\n\n" before thinking) doesn't count as an answer.
                        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { gotContent.value = true }
                        if detector.feed(content) { throw VisionError.degenerateOutput }
                        continuation.yield(content)
                    }
                } catch let error as VisionError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Self.mapNetwork(error)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(firstTokenTimeout))
                if !gotContent.value { deadlineHit.value = true; session.invalidateAndCancel(); throw VisionError.timeout }
                try await Task.sleep(for: .seconds(max(0, totalTimeout - firstTokenTimeout)))
                deadlineHit.value = true
                session.invalidateAndCancel()
                throw VisionError.timeout
            }
            // Whichever finishes first decides: reader done → stop the watcher; watcher threw → stop the reader.
            defer { group.cancelAll() }
            try await group.next()
        }
        } catch let error as VisionError where error == .cancelled && deadlineHit.value {
            throw VisionError.timeout // our own deadline tore the stream down
        } catch let error as VisionError where error == .network("cancelled") && deadlineHit.value {
            throw VisionError.timeout
        }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// The HTTP request for `request` in the provider's format.
    static func makeURLRequest(_ request: VisionRequest, endpoint: URL, key: String, wire: Wire, timeout: Double) throws -> URLRequest {
        var body: [String: Any] = [
            "model": request.model.id,
            "stream": true,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": [["type": "text", "text": request.userText]]
                    + request.jpegs.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }],
            ],
        ]
        for (k, v) in request.model.extraBody { body[k] = v.foundation }
        if wire == .anthropicMessages {
            // Messages API: the system prompt is a top-level field; images come before the text they're about.
            body = [
                "model": request.model.id,
                "stream": true,
                "max_tokens": request.maxTokens,
                "temperature": request.temperature,
                "system": request.systemPrompt,
                "messages": [["role": "user", "content":
                    request.jpegs.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]] }
                    + [["type": "text", "text": request.userText]]]],
            ]
        }

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        if wire == .anthropicMessages {
            if !key.isEmpty { urlRequest.setValue(key, forHTTPHeaderField: "x-api-key") }
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// One server-sent event line: answer text, the end of the answer, or nothing useful. Throws the service's error.
    enum StreamItem: Equatable { case text(String), done, skip }

    static func parse(line: String, wire: Wire) throws -> StreamItem {
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .skip }
        // NIM reports overload inside a 200 stream: {"error": {"message": "ResourceExhausted: …", "code": 500}};
        // Anthropic sends {"type": "error", "error": {"type": "overloaded_error", …}}.
        if let error = json["error"] as? [String: Any] {
            if (error["type"] as? String) == "overloaded_error" { throw VisionError.http(429, "overloaded") }
            throw streamError(error)
        }
        switch wire {
        case .anthropicMessages:
            if (json["type"] as? String) == "message_stop" { return .done }
            guard (json["type"] as? String) == "content_block_delta", let delta = json["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta", let text = delta["text"] as? String, !text.isEmpty else { return .skip }
            return .text(text)
        case .openAIChat:
            guard let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String, !text.isEmpty else { return .skip }
            return .text(text)
        }
    }

    static func mapNetwork(_ error: Error) -> VisionError {
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorCancelled: return .cancelled
            default: return .network(ns.localizedDescription)
            }
        }
        return .network(String(describing: error))
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

