import XCTest
@testable import WispCore

final class WebActionTests: XCTestCase {
    func testSearch() {
        XCTAssertEqual(WebAction.parse("can you go online and search for cute cat videos"), .search("cute cat videos"))
        XCTAssertEqual(WebAction.parse("Search the web for best pizza near me"), .search("best pizza near me"))
        XCTAssertEqual(WebAction.parse("google how tall is the Eiffel Tower"), .search("how tall is the Eiffel Tower"))
        XCTAssertEqual(WebAction.parse("look up flights to Paris online"), .search("flights to Paris"))
        XCTAssertEqual(WebAction.parse("open the browser and search for weather in Austin"), .search("weather in Austin"))
        XCTAssertEqual(WebAction.search("a b").url.absoluteString, "https://www.google.com/search?q=a%20b")
    }

    func testOpen() {
        XCTAssertEqual(WebAction.parse("open YouTube"), .open(name: "YouTube", url: URL(string: "https://www.youtube.com")!))
        XCTAssertEqual(WebAction.parse("go to apple.com"), .open(name: "apple.com", url: URL(string: "https://apple.com")!))
        XCTAssertEqual(WebAction.parse("take me to gmail please"), .open(name: "Gmail", url: URL(string: "https://mail.google.com")!))
    }

    func testNotWebActions() {
        for q in ["how do I search in this app", "search for the export button", "open the file menu", "how do I open YouTube",
                  "what's the weather like", "open settings"] {
            XCTAssertNil(WebAction.parse(q), q)
        }
    }
}

final class SiteSearchTests: XCTestCase {
    func testSiteSearches() {
        guard case .siteSearch(let name, let q, let url)? = WebAction.parse("can you open up my browser and open Instagram and search for improving Claude Code setup") else {
            return XCTFail("not a site search")
        }
        XCTAssertEqual(name, "Instagram"); XCTAssertEqual(q, "improving Claude Code setup")
        XCTAssertEqual(url.absoluteString, "https://www.instagram.com/explore/search/keyword/?q=improving%20Claude%20Code%20setup")
        XCTAssertEqual(WebAction.parse("search YouTube for lofi music")?.url.absoluteString, "https://www.youtube.com/results?search_query=lofi%20music")
        XCTAssertEqual(WebAction.parse("look up running shoes on Amazon")?.url.absoluteString, "https://www.amazon.com/s?k=running%20shoes")
    }
}
