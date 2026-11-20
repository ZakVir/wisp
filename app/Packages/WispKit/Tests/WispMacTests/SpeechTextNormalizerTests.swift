import XCTest
import AVFoundation
@testable import WispMac

final class SpeechTextNormalizerTests: XCTestCase {
    func testAbbreviationsAreSpelledOut() {
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Save it as a PDF."), "Save it as a P D F.")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Open the URLs"), "Open the U R L's")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Plug in the USB cable"), "Plug in the U S B cable")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Ask the AI"), "Ask the ay I")
    }

    func testWordsAndSystemNames() {
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("a JPEG from NASA"), "a JPEG from NASA")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Update macOS and iPadOS"), "Update mac O S and iPad O S")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Click OK"), "Click okay")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("I think so"), "I think so")
        XCTAssertEqual(SpeechTextNormalizer.spellAcronyms("Open Safari"), "Open Safari")
    }
}

final class ShortcutGlyphSpeechTests: XCTestCase {
    func testArrowsAndKeysAfterModifiers() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("Press ⌘→ to go to the end."), "Press Command Right Arrow to go to the end.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Press ⎋ to close."), "Press Escape to close.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Choose View > Show Sidebar."), "Choose View, then Show Sidebar.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Go to File → Export."), "Go to File, then Export.")
    }
}

final class SpokenLanguageTests: XCTestCase {
    func testLanguageOfASentence() {
        XCTAssertNil(SpokenLanguage.nonEnglishCode("Click the Export button in the top right corner."))
        XCTAssertNil(SpokenLanguage.nonEnglishCode("Hola."), "too short to tell")
        if AVSpeechSynthesisVoice(language: "es") != nil {
            XCTAssertEqual(SpokenLanguage.nonEnglishCode("Haz clic en el botón Exportar en la esquina superior derecha."), "es")
        }
    }
}

final class LinkSpeechTests: XCTestCase {
    func testLinksAreSaidAsTheirSite() {
        XCTAssertEqual(SpeechTextNormalizer.speakableLinks("Read more at https://www.example.com/news/2026?id=4 today."),
                       "Read more at a link to example.com today.")
        XCTAssertEqual(SpeechTextNormalizer.speakableLinks("Go to www.apple.com/support"), "Go to a link to apple.com")
        XCTAssertEqual(SpeechTextNormalizer.speakableLinks("No links here."), "No links here.")
    }
}
