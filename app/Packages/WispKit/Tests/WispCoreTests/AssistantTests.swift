import XCTest
@testable import WispCore

final class ResponseParserTests: XCTestCase {
    func testStreamingTaggedLines() {
        var p = ResponseParser()
        var events: [AssistantEvent] = []
        for chunk in ["SAY: Click Exp", "ort in the top right.\nPOI", "NT: 1290, 790 | Export\nSAY: Then choose PDF."] {
            events += p.consume(chunk)
        }
        XCTAssertEqual(events, [.say("Click Export in the top right."), .point(x: 1290, y: 790, label: "Export")])
        events += p.finish()
        XCTAssertEqual(events.last, .say("Then choose PDF."))
    }

    func testShapesAndTolerantFormats() {
        XCTAssertEqual(ResponseParser.parseLine("CIRCLE: 1180, 760, 220, 60 | Export button"),
                       .circle(x: 1180, y: 760, width: 220, height: 60, label: "Export button"))
        XCTAssertEqual(ResponseParser.parseLine("**POINT:** (812, 404) \"Save\""), .point(x: 812, y: 404, label: "Save"))
        XCTAssertEqual(ResponseParser.parseLine("- point: x=10.5 y=20 | A"), .point(x: 10.5, y: 20, label: "A"))
        XCTAssertEqual(ResponseParser.parseLine("ARROW: 1,2,3,4 | to"), .arrow(x1: 1, y1: 2, x2: 3, y2: 4, label: "to"))
        XCTAssertEqual(ResponseParser.parseLine("UNDERLINE: 1,2,3,4"), .underline(x1: 1, y1: 2, x2: 3, y2: 4, label: ""))
        XCTAssertEqual(ResponseParser.parseLine("PATH: 1,1 2,2 3,3 | s"), .path(points: [Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)], label: "s"))
    }

    func testUntaggedTextIsSpeechAndBadGeometryIsDropped() {
        XCTAssertEqual(ResponseParser.parseLine("It's the blue button: Export."), .say("It's the blue button: Export."))
        XCTAssertNil(ResponseParser.parseLine("POINT: somewhere | Export"))
        XCTAssertNil(ResponseParser.parseLine("CIRCLE: 1, 2 | too few"))
        XCTAssertNil(ResponseParser.parseLine("```"))
        XCTAssertNil(ResponseParser.parseLine("   "))
        XCTAssertNil(ResponseParser.parseLine("SAY:   "))
    }

    func testTagsOnOneLineAreSplit() {
        var p = ResponseParser()
        let events = p.consume("SAY: It is in the bottom right corner. POINT: 1430, 790 | Export\n")
        XCTAssertEqual(events, [.say("It is in the bottom right corner."), .point(x: 1430, y: 790, label: "Export")])
        XCTAssertEqual(ResponseParser.parseSegments("Use the ARROW key."), [.say("Use the ARROW key.")])
    }

    func testScreenSuffix() {
        XCTAssertEqual(ResponseParser.parseLine("POINT: 400, 300 | terminal | screen 2"),
                       .onScreen(2, .point(x: 400, y: 300, label: "terminal")))
        XCTAssertEqual(ResponseParser.parseLine("POINT: 400, 300 | terminal:screen2"),
                       .onScreen(2, .point(x: 400, y: 300, label: "terminal")))
        XCTAssertEqual(ResponseParser.parseLine("POINT: 5, 6 | Save | screen 1"), .point(x: 5, y: 6, label: "Save"))
        XCTAssertEqual(AssistantEvent.onScreen(3, .point(x: 1, y: 2, label: "")).screenAndEvent.0, 2)
        XCTAssertEqual(AssistantEvent.point(x: 1, y: 2, label: "").screenAndEvent.0, 0)
    }

    func testSentenceSplitter() {
        XCTAssertEqual(SentenceSplitter.split("Click Export. Then choose PDF! Done?"), ["Click Export.", "Then choose PDF!", "Done?"])
        XCTAssertEqual(SentenceSplitter.split("No punctuation here"), ["No punctuation here"])
    }
}

final class DegenerateDetectorTests: XCTestCase {
    func testKimiExclamationRunsAreCaught() {
        XCTAssertTrue(DegenerateOutputDetector.isDegenerate("SAY: Click Export!!!!!!!!!!!!!!"))
        var d = DegenerateOutputDetector()
        XCTAssertFalse(d.feed("SAY: Click "))
        XCTAssertFalse(d.feed("Export!!!"))
        XCTAssertTrue(d.feed("!!!!!!!!"))
    }

    func testNormalTextIsFine() {
        XCTAssertFalse(DegenerateOutputDetector.isDegenerate("SAY: Click Export in the top right...\nPOINT: 1290, 790 | Export"))
        XCTAssertFalse(DegenerateOutputDetector.isDegenerate("SAY: Use the ------ divider."))
    }

    func testRepetitionLoops() {
        XCTAssertTrue(DegenerateOutputDetector.isDegenerate(Array(repeating: "the", count: 14).joined(separator: " ")))
        XCTAssertTrue(DegenerateOutputDetector.isDegenerate(String(repeating: "?! ", count: 30)))
    }
}

final class PromptTests: XCTestCase {
    func testUserTextIncludesFactsButNeverExtraContent() {
        let facts = TurnFacts(imageSize: PixelSize(width: 1456, height: 946), cursorInImage: Vec2(100.4, 200.6),
                              frontmostAppName: "Pages", question: "Where is export?")
        let text = PromptBuilder.userText(facts)
        XCTAssertTrue(text.contains("1456 x 946"))
        XCTAssertTrue(text.contains("100, 200"))
        XCTAssertTrue(text.contains("Frontmost app: Pages."))
        XCTAssertTrue(text.hasSuffix("\"Where is export?\""))
        XCTAssertTrue(PromptBuilder.systemPrompt(space: .normalized1000).contains("0-1000"))
    }

    func testCatalogDefaultsAndExtras() {
        // Kimi K3 is retired on NIM: asking for it gives Nemotron 3.5 Super VL, with thinking off.
        let kimi = VisionModelCatalog.info(for: "moonshotai/kimi-k3")
        XCTAssertEqual(kimi.id, "nvidia/nemotron-3.5-super-vl-120b-a12b")
        XCTAssertEqual(kimi.extraBody["chat_template_kwargs"], .object(["enable_thinking": .bool(false)]))
        XCTAssertEqual(VisionModelCatalog.info(for: "stepfun-ai/step-5-preview").extraBody["reasoning_effort"], .string("low"))
        XCTAssertEqual(VisionModelCatalog.info(for: "unknown/x").displayName, "unknown/x")
    }
}

final class PointingScoreTests: XCTestCase {
    func testAimAndHit() {
        let size = PixelSize(width: 1000, height: 500)
        let box: [Double] = [100, 100, 200, 140]
        let p = PointingScore.aimPoint(of: [.say("hi"), .point(x: 150, y: 120, label: "")], space: .imagePixels, imageSize: size)!
        XCTAssertTrue(PointingScore.isHit(p, box: box))
        let c = PointingScore.aimPoint(of: [.circle(x: 90, y: 90, width: 120, height: 60, label: "")], space: .imagePixels, imageSize: size)!
        XCTAssertEqual(c, Vec2(150, 120))
        let n = PointingScore.aimPoint(of: [.onScreen(2, .point(x: 150, y: 240, label: ""))], space: .normalized1000, imageSize: size)!
        XCTAssertEqual(n, Vec2(150, 120))
        XCTAssertEqual(PointingScore.distance(from: Vec2(203, 144), toBox: box), 5, accuracy: 1e-9)
        XCTAssertTrue(PointingScore.isHit(Vec2(203, 144), box: box))
        XCTAssertFalse(PointingScore.isHit(Vec2(220, 120), box: box))
        XCTAssertNil(PointingScore.aimPoint(of: [.say("no")], space: .imagePixels, imageSize: size))
    }
}

final class QuestionIntentTests: XCTestCase {
    func testAboutAssistant() {
        for q in ["What can you do?", "who are you", "Hey, what are you?", "What’s your name?", "How do I use you?", "what else can you do for me"] {
            XCTAssertTrue(QuestionIntent.isAboutAssistant(q), q)
        }
        for q in ["How do I export this?", "What can I do with this menu?", "Where is the share button?", "What are these icons?",
                  "What does Claude do here?", "Can you show me where settings are?"] {
            XCTAssertFalse(QuestionIntent.isAboutAssistant(q), q)
        }
        for q in ["What's your job?", "Are you Claude?", "Can you remember what I asked before?", "Who made you?",
                  "what are you", "What do you do?", "what can you help with", "can you click things for me"] {
            XCTAssertTrue(QuestionIntent.isAboutAssistant(q), q)
        }
        // Screen questions that merely contain "you".
        for q in ["What are you looking at here?", "Can you click the Save button?", "what do you do when this error shows",
                  "What can you help me find on this page?"] {
            XCTAssertFalse(QuestionIntent.isAboutAssistant(q), q)
        }
    }

    func testDeniesPresence() {
        for s in ["I don't see an undo button in the Photo Editor.", "There's no contact page on this site.",
                  "I can't see the prices on this page.", "There isn't a settings option here.", "Prices aren't shown here."] {
            XCTAssertTrue(QuestionIntent.deniesPresence(s), s)
        }
        for s in ["Click Export at the bottom right.", "No problem, click Cancel.", "There's a Share button at the top.",
                  "There's no need to scroll, Export is top right.",
                  "If you don't see it, scroll down and click Save."] {
            XCTAssertFalse(QuestionIntent.deniesPresence(s), s)
        }
    }

    func testAsksBack() {
        XCTAssertTrue(QuestionIntent.asksBack("To do what, exactly?"))
        XCTAssertTrue(QuestionIntent.asksBack("Which photo do you mean?\""))
        XCTAssertFalse(QuestionIntent.asksBack("Click Export."))
        XCTAssertTrue(QuestionIntent.isAboutAssistant("can you do the math for me"))
    }

    func testAboutHintInUserText() {
        let facts = TurnFacts(imageSize: PixelSize(width: 10, height: 10), cursorInImage: nil, frontmostAppName: nil, question: "What can you help with?")
        XCTAssertTrue(PromptBuilder.userText(facts).contains("about you, Wisp"))
        let other = TurnFacts(imageSize: PixelSize(width: 10, height: 10), cursorInImage: nil, frontmostAppName: nil, question: "How do I export?")
        XCTAssertFalse(PromptBuilder.userText(other).contains("about you, Wisp"))
    }

    func testSmallTalk() {
        for q in ["Hey", "Thanks!", "Never mind", "Good morning.", "Test test", "Um", "Can you hear me?", "hello there", "sorry wrong button", "oops"] {
            XCTAssertTrue(QuestionIntent.isSmallTalk(q), q)
            XCTAssertFalse(QuestionIntent.allowsPointing(q), q)
        }
        for q in ["export", "help", "Hey, where's the export button?", "Thanks, how do I crop it?"] {
            XCTAssertFalse(QuestionIntent.isSmallTalk(q), q)
        }
        XCTAssertTrue(QuestionIntent.allowsPointing("How do I export this?"))
    }
}

final class TopicLineTests: XCTestCase {
    func testTopicParsingNeverSpoken() {
        XCTAssertEqual(ResponseParser.parseLine("TOPIC: screen"), .topic(.screen))
        XCTAssertEqual(ResponseParser.parseLine("TOPIC: Other"), .topic(.other))
        XCTAssertEqual(ResponseParser.parseLine("TOPIC: you"), .topic(.you))
        XCTAssertEqual(ResponseParser.parseLine("TOPIC: wisp"), .topic(.you))
        XCTAssertEqual(ResponseParser.parseLine("**TOPIC:** screen."), .topic(.screen))
        XCTAssertEqual(ResponseParser.parseLine("TOPIC: weather"), .topic(.other), "unknown readings never allow pointing")
        XCTAssertFalse(AssistantEvent.topic(.screen).isVisual)
        var p = ResponseParser()
        XCTAssertEqual(p.consume("TOPIC: other\nSAY: Paris.\n"), [.topic(.other), .say("Paris.")])
    }
}

final class SentenceNamesTests: XCTestCase {
    func testSentenceNamesItsOwnPoint() {
        XCTAssertTrue(QuestionIntent.sentenceNames(label: "Subscribe", in: "Yes, click the Subscribe button at the top."))
        XCTAssertTrue(QuestionIntent.sentenceNames(label: "First Aid", in: "First Aid is a tool in Disk Utility that checks disks."))
        XCTAssertTrue(QuestionIntent.sentenceNames(label: "Rand", in: "Rand gives you a random number between 0 and 1."))
        XCTAssertTrue(QuestionIntent.sentenceNames(label: "Export button", in: "Use Export in the toolbar."))
        XCTAssertTrue(QuestionIntent.sentenceNames(label: "e", in: "The \"e\" button is Euler's number."))
    }

    func testUnrelatedOrEmptyLabelsDoNotCount() {
        XCTAssertFalse(QuestionIntent.sentenceNames(label: "Resume", in: "I'm a timer app, not a fitness coach."))
        XCTAssertFalse(QuestionIntent.sentenceNames(label: "Claude logo", in: "I can help with that, but I don't see anything to point to."))
        XCTAssertFalse(QuestionIntent.sentenceNames(label: "not visible", in: "I don't see an undo button, but it's not visible here."))
        XCTAssertFalse(QuestionIntent.sentenceNames(label: "e", in: "Here is the answer."))
        XCTAssertFalse(QuestionIntent.sentenceNames(label: "Checkout", in: "Checkouts are quick."), "whole word only")
    }

    func testEventLabel() {
        XCTAssertEqual(AssistantEvent.point(x: 1, y: 2, label: "Save").label, "Save")
        XCTAssertEqual(AssistantEvent.onScreen(2, .circle(x: 0, y: 0, width: 1, height: 1, label: "Done")).label, "Done")
        XCTAssertNil(AssistantEvent.say("hi").label)
    }

    func testLeakedReasoningAndWordlessLinesAreNeverSpoken() {
        var p = ResponseParser()
        var events = p.consume(", however</think>\n\n,\n")
        events += p.finish()
        XCTAssertTrue(events.isEmpty, "a reply that is only leaked thinking and punctuation produces nothing: \(events)")

        var q = ResponseParser()
        var out = q.consume("TOPIC: screen\n<think>the user wants to export, the butt")
        out += q.consume("on is at the top</think>SAY: Click Export at the top.\nPOINT: 900, 60 | Export\n")
        out += q.finish()
        XCTAssertEqual(out, [.topic(.screen), .say("Click Export at the top."), .point(x: 900, y: 60, label: "Export")])

        var r = ResponseParser()
        XCTAssertEqual(r.consume("---\nSAY: Hi there.\n"), [.say("Hi there.")])
    }

    func testHedgeBeforeAnOffScreenAnswerIsDropped() {
        XCTAssertEqual(QuestionIntent.withoutHedge("I can't help with cooking, but here's how to cook rice: rinse it first."),
                       "Here's how to cook rice: rinse it first.")
        XCTAssertEqual(QuestionIntent.withoutHedge("I don't see the weather on your screen, but London's weather is usually mild."),
                       "London's weather is usually mild.")
        XCTAssertEqual(QuestionIntent.withoutHedge("I can't help with that."), "I can't help with that.", "nothing follows: unchanged")
        XCTAssertEqual(QuestionIntent.withoutHedge("Rice cooks in about 18 minutes."), "Rice cooks in about 18 minutes.")
        XCTAssertEqual(QuestionIntent.withoutHedge("I don't see it, but ok."), "I don't see it, but ok.", "too short to stand alone")
    }
}
