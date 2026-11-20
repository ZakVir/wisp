import XCTest
@testable import WispCore

final class ReadAloudTests: XCTestCase {
    func testReadAloudRequests() {
        for q in ["read this to me", "Read this.", "can you read that out loud", "read it aloud please",
                  "read what I've selected", "please read the selected text", "Read the highlighted part for me"] {
            XCTAssertTrue(QuestionIntent.isReadAloud(q), q)
        }
        for q in ["read this and summarize it", "what does this say", "how do I read this file", "read me a poem",
                  "can you read my screen"] {
            XCTAssertFalse(QuestionIntent.isReadAloud(q), q)
        }
    }
}

final class RepeatTests: XCTestCase {
    func testRepeatRequests() {
        for q in ["say that again", "Sorry, can you repeat that?", "what did you say", "repeat what you just said",
                  "Come again?", "pardon"] {
            XCTAssertTrue(QuestionIntent.isRepeat(q), q)
        }
        for q in ["repeat this pattern in Excel", "how do I say that in French", "what did you say about the button earlier and why"] {
            XCTAssertFalse(QuestionIntent.isRepeat(q), q)
        }
    }
}

final class ShortcutListTests: XCTestCase {
    func testShortcutListRequests() {
        for q in ["what are the keyboard shortcuts here", "Show me the shortcuts.", "list the shortcuts for this app",
                  "keyboard shortcuts", "what are the shortcuts in this app?"] {
            XCTAssertTrue(QuestionIntent.isShortcutList(q), q)
        }
        for q in ["what's the shortcut for copy", "how do I make a shortcut on my desktop", "shortcuts app"] {
            XCTAssertFalse(QuestionIntent.isShortcutList(q), q)
        }
    }
}

final class CopyScreenTextTests: XCTestCase {
    func testCopyRequests() {
        for q in ["copy the text on my screen", "Copy all the text in this image.", "can you grab the text from this video",
                  "copy what's on the screen", "get the text from this picture please"] {
            XCTAssertTrue(QuestionIntent.isCopyScreenText(q), q)
        }
        for q in ["how do I copy text", "copy this file", "what does the text on my screen say"] {
            XCTAssertFalse(QuestionIntent.isCopyScreenText(q), q)
        }
    }
}

final class ReadPageTests: XCTestCase {
    func testReadPageRequests() {
        for q in ["read this page to me", "Read the article out loud.", "can you read my email aloud", "read me this story"] {
            XCTAssertTrue(QuestionIntent.isReadPage(q), q)
        }
        XCTAssertFalse(QuestionIntent.isReadPage("how do I read this page faster"))
    }
}

final class ClipboardQuestionTests: XCTestCase {
    func testMentions() {
        XCTAssertTrue(QuestionIntent.mentionsClipboard("what does what I copied mean"))
        XCTAssertTrue(QuestionIntent.mentionsClipboard("translate my clipboard into French"))
        XCTAssertTrue(QuestionIntent.mentionsClipboard("is the link I copied safe?"))
        XCTAssertFalse(QuestionIntent.mentionsClipboard("how do I copy this file"))
        var facts = TurnFacts(imageSize: PixelSize(width: 1, height: 1), cursorInImage: nil, frontmostAppName: nil, question: "q")
        facts.clipboardText = "bonjour"
        XCTAssertTrue(PromptBuilder.userText(facts).contains("The text they copied (on their clipboard): \"bonjour\""))
    }
}

final class MagnifyTests: XCTestCase {
    func testMagnify() {
        for q in ["magnify this", "give me a closer look", "show me this bigger", "Can you zoom in on this for me?"] {
            XCTAssertTrue(QuestionIntent.isMagnify(q), q)
        }
        for q in ["how do I make it bigger", "how do I zoom in", "make the words bigger"] {
            XCTAssertFalse(QuestionIntent.isMagnify(q), q)
        }
    }
}

final class RetryTests: XCTestCase {
    func testRetry() {
        for q in ["try again", "No, that's not right.", "second opinion", "are you sure?", "look again"] {
            XCTAssertTrue(QuestionIntent.isRetry(q), q)
        }
        XCTAssertFalse(QuestionIntent.isRetry("how do I try again in this game"))
        XCTAssertFalse(QuestionIntent.isRetry("say that again"), "that's repeat, not retry")
    }
}

final class ReadClipboardTests: XCTestCase {
    func testReadClipboard() {
        XCTAssertTrue(QuestionIntent.isReadClipboard("read what I copied"))
        XCTAssertTrue(QuestionIntent.isReadClipboard("read my clipboard out loud"))
        XCTAssertFalse(QuestionIntent.isReadClipboard("what did I copy"))
    }
}

final class CapabilitiesTests: XCTestCase {
    func testCapabilities() {
        XCTAssertTrue(QuestionIntent.asksCapabilities("what can you do?"))
        XCTAssertTrue(QuestionIntent.asksCapabilities("What can you help with"))
        XCTAssertFalse(QuestionIntent.asksCapabilities("what can you do with this photo"))
    }
}

final class KeepReadingTests: XCTestCase {
    func testChunks() {
        XCTAssertTrue(QuestionIntent.isKeepReading("keep reading"))
        XCTAssertTrue(QuestionIntent.isKeepReading("Read more."))
        XCTAssertFalse(QuestionIntent.isKeepReading("read more about this"))
        let text = String(repeating: "A sentence here. ", count: 10)
        let (first, rest) = QuestionIntent.readingChunk(text, limit: 50)
        XCTAssertTrue(first.hasSuffix("."))
        XCTAssertLessThanOrEqual(first.count, 50)
        XCTAssertNotNil(rest)
        XCTAssertNil(QuestionIntent.readingChunk("short.", limit: 50).1)
    }
}
