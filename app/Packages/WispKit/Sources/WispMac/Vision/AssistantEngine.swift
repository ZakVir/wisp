import Foundation
import WispCore

/// Timings of one vision request (no content).
public struct VisionTiming: Sendable {
    public var modelID: String
    public var requestSentUptime: TimeInterval
    public var firstTokenUptime: TimeInterval?
    public var doneUptime: TimeInterval?
    public var attempts: Int
}

/// What the engine streams back for one question.
public enum AssistantOutput: Sendable {
    /// An event and the coordinate space of the model that produced it.
    case event(AssistantEvent, ModelCoordinateSpace)
    /// The request finished (successfully or not); `error` carries a user-facing failure.
    case finished(VisionTiming, VisionError?)
}

/// Asks the vision model about a screenshot and streams parsed events. If the primary model fails before it
/// has said anything (timeout, garbled output such as Kimi's "!!!!" runs, HTTP error), the next fallback model
/// is tried with the same request.
///
/// NIM's free tier often answers "busy" (shared workers full) within ~0.3 s, and Kimi's glitch shows up as quickly.
/// Both are random per request, but an immediate retry only got through 3 times in 9 (measured 2026-10-01), so after
/// a quick failure the engine *hedges*: it retries the primary and starts the first fallback at the same time, and
/// whichever says something first wins; the other is cancelled.
public final class AssistantEngine: Sendable {
    private let client: VisionClient

    public init(client: VisionClient) {
        self.client = client
    }

    public func ask(jpegs: [Data], facts: TurnFacts, models: [VisionModelInfo], frontmostBundleID: String?,
                    firstTokenTimeout: Double, totalTimeout: Double) -> AsyncStream<AssistantOutput> {
        AsyncStream { continuation in
            let task = Task {
                var timing = VisionTiming(modelID: models.first?.id ?? "", requestSentUptime: ProcessInfo.processInfo.systemUptime,
                                          firstTokenUptime: nil, doneUptime: nil, attempts: 0)
                var lastError: VisionError?
                var queue = models[...]
                var lanes: [VisionModelInfo] = queue.popFirst().map { [$0] } ?? []
                var hedged = false
                while !lanes.isEmpty, !Task.isCancelled {
                    timing.attempts += lanes.count
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = await race(lanes, jpegs: jpegs, facts: facts, frontmostBundleID: frontmostBundleID,
                                            firstTokenTimeout: firstTokenTimeout, totalTimeout: totalTimeout, continuation: continuation)
                    for (model, error) in result.failures {
                        Log.vision.error("vision \(model.id, privacy: .public) failed: \(error.code, privacy: .public)")
                    }
                    if let winner = result.winner {
                        // Something was said: never start over with another model (it would repeat itself).
                        timing.modelID = winner.id
                        timing.firstTokenUptime = result.firstChunkUptime
                        lastError = result.winnerError
                        break
                    }
                    lastError = result.failures.last?.1 ?? .degenerateOutput
                    if result.failures.contains(where: { !$0.1.isRetryableWithAnotherModel }) { break }
                    let quick = ProcessInfo.processInfo.systemUptime - started < 8
                        && result.failures.allSatisfy { $0.1 == .degenerateOutput || $0.1.isBusy }
                    if !hedged, quick, lanes.count == 1 {
                        hedged = true
                        lanes = [lanes[0]] + (queue.popFirst().map { [$0] } ?? [])
                    } else {
                        lanes = queue.popFirst().map { [$0] } ?? []
                    }
                }
                timing.doneUptime = ProcessInfo.processInfo.systemUptime
                continuation.yield(.finished(timing, lastError == .cancelled ? nil : lastError))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct RaceResult {
        var winner: VisionModelInfo?
        var winnerError: VisionError?
        var firstChunkUptime: Double?
        var failures: [(VisionModelInfo, VisionError)] = []
    }

    /// Streams the same question from each model at once. The first to produce a parsed event owns the output;
    /// the others stop at their next chunk (their HTTP streams are torn down with them).
    private func race(_ lanes: [VisionModelInfo], jpegs: [Data], facts: TurnFacts, frontmostBundleID: String?,
                      firstTokenTimeout: Double, totalTimeout: Double,
                      continuation: AsyncStream<AssistantOutput>.Continuation) async -> RaceResult {
        let owner = RaceOwner()
        let client = self.client
        return await withTaskGroup(of: (Int, Double?, VisionError?, Bool).self) { group in
            for (index, model) in lanes.enumerated() {
                group.addTask {
                    let request = VisionRequest(model: model, systemPrompt: PromptBuilder.systemPrompt(space: model.coordinateSpace),
                                                userText: PromptBuilder.userText(facts, space: model.coordinateSpace), jpegs: jpegs)
                    var parser = ResponseParser()
                    var firstChunk: Double?
                    // The TOPIC line arrives first but isn't an answer: hold it until the lane says or shows
                    // something, so a reply that glitches right after it can still fall back.
                    var held: [AssistantEvent] = []
                    func deliver(_ events: [AssistantEvent]) -> Bool {
                        guard !events.isEmpty else { return true }
                        if !owner.isWinner(index) {
                            // "STEPS: done" on its own is an answer too (a walkthrough's "you're finished").
                            guard events.contains(where: { event in
                                switch event {
                                case .topic: return false
                                case .steps(let more): return !more
                                default: return true
                                }
                            }) else {
                                held += events
                                return !owner.lost(index)
                            }
                            guard owner.claim(index) else { return false }
                        }
                        for event in held + events { continuation.yield(.event(event, model.coordinateSpace)) }
                        held.removeAll()
                        return true
                    }
                    do {
                        for try await chunk in client.stream(request, frontmostBundleID: frontmostBundleID,
                                                             firstTokenTimeout: firstTokenTimeout, totalTimeout: totalTimeout) {
                            if firstChunk == nil { firstChunk = ProcessInfo.processInfo.systemUptime }
                            if owner.lost(index) || !deliver(parser.consume(chunk)) { return (index, nil, nil, false) }
                        }
                        if !deliver(parser.finish()) { return (index, nil, nil, false) }
                        return owner.isWinner(index) ? (index, firstChunk, nil, true) : (index, nil, .degenerateOutput, false)
                    } catch let error as VisionError {
                        if owner.lost(index) { return (index, nil, nil, false) }
                        return (index, firstChunk, error, owner.isWinner(index))
                    } catch {
                        return (index, firstChunk, .network(String(describing: error)), owner.isWinner(index))
                    }
                }
            }
            var result = RaceResult()
            for await (index, firstChunk, error, won) in group {
                if won {
                    result.winner = lanes[index]
                    result.firstChunkUptime = firstChunk
                    result.winnerError = error
                    group.cancelAll()
                } else if let error {
                    result.failures.append((lanes[index], error))
                }
            }
            return result
        }
    }
}

/// Which racing lane owns the answer (the first to produce an event).
final class RaceOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var winner: Int?
    func claim(_ index: Int) -> Bool { lock.withLock { if winner == nil { winner = index }; return winner == index } }
    func lost(_ index: Int) -> Bool { lock.withLock { winner != nil && winner != index } }
    func isWinner(_ index: Int) -> Bool { lock.withLock { winner == index } }
}
