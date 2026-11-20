import Foundation

/// Extra text context added to the vision prompt (for example company glossary or documentation in a
/// future company edition). The personal edition uses `EmptyContextProvider`.
public protocol ContextProvider: Sendable {
    /// Returns context snippets for this turn. Must be fast (it runs after key-up) and must not block.
    func context(for request: ContextRequest) async -> [ContextSnippet]
}

public struct ContextRequest: Sendable {
    public var transcript: String
    public var frontmostBundleID: String?
    public init(transcript: String, frontmostBundleID: String?) {
        self.transcript = transcript
        self.frontmostBundleID = frontmostBundleID
    }
}

public struct ContextSnippet: Sendable, Equatable {
    public var title: String
    public var text: String
    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public struct EmptyContextProvider: ContextProvider {
    public init() {}
    public func context(for request: ContextRequest) async -> [ContextSnippet] { [] }
}
