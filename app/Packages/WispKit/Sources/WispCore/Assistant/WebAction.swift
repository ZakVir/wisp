import Foundation

/// Simple things Wisp does in the browser when asked ("search online for …", "open YouTube"): it opens the search or
/// site in a new tab of the default browser. Nothing else is ever clicked or typed.
public enum WebAction: Equatable, Sendable {
    case search(String)
    case open(name: String, url: URL)
    /// "Open Instagram and search for …": the site's own search results.
    case siteSearch(name: String, query: String, url: URL)

    /// Search pages of common sites (the query is appended, URL-encoded).
    private static let siteSearches: [String: (String, String, String)] = [
        "youtube": ("YouTube", "youtube.com", "https://www.youtube.com/results?search_query="),
        "instagram": ("Instagram", "instagram.com", "https://www.instagram.com/explore/search/keyword/?q="),
        "amazon": ("Amazon", "amazon.com", "https://www.amazon.com/s?k="),
        "reddit": ("Reddit", "reddit.com", "https://www.reddit.com/search/?q="),
        "wikipedia": ("Wikipedia", "wikipedia.org", "https://en.wikipedia.org/w/index.php?search="),
        "github": ("GitHub", "github.com", "https://github.com/search?q="),
        "google maps": ("Google Maps", "maps.google.com", "https://www.google.com/maps/search/"),
        "maps": ("Google Maps", "maps.google.com", "https://www.google.com/maps/search/"),
        "twitter": ("X", "x.com", "https://x.com/search?q="), "x": ("X", "x.com", "https://x.com/search?q="),
        "spotify": ("Spotify", "open.spotify.com", "https://open.spotify.com/search/"),
        "linkedin": ("LinkedIn", "linkedin.com", "https://www.linkedin.com/search/results/all/?keywords="),
        "netflix": ("Netflix", "netflix.com", "https://www.netflix.com/search?q="),
        "tiktok": ("TikTok", "tiktok.com", "https://www.tiktok.com/search?q="),
        "pinterest": ("Pinterest", "pinterest.com", "https://www.pinterest.com/search/pins/?q="),
        "google": ("Google", "google.com", "https://www.google.com/search?q="),
    ]

    /// The address to type for a site ("Instagram" → "instagram.com").
    public static func domain(forSite name: String) -> String? {
        siteSearches.first { $0.value.0 == name }?.value.1
    }

    private static func siteSearch(site: String, query: String) -> WebAction? {
        guard let (name, _, base) = siteSearches[site.lowercased()], !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?/#"))),
              let url = URL(string: base + encoded) else { return nil }
        return .siteSearch(name: name, query: query, url: url)
    }

    private static let sites: [String: (String, String)] = [
        "youtube": ("YouTube", "https://www.youtube.com"), "google": ("Google", "https://www.google.com"),
        "gmail": ("Gmail", "https://mail.google.com"), "google maps": ("Google Maps", "https://maps.google.com"),
        "maps": ("Google Maps", "https://maps.google.com"), "google drive": ("Google Drive", "https://drive.google.com"),
        "google docs": ("Google Docs", "https://docs.google.com"), "wikipedia": ("Wikipedia", "https://www.wikipedia.org"),
        "amazon": ("Amazon", "https://www.amazon.com"), "netflix": ("Netflix", "https://www.netflix.com"),
        "github": ("GitHub", "https://github.com"), "reddit": ("Reddit", "https://www.reddit.com"),
        "facebook": ("Facebook", "https://www.facebook.com"), "instagram": ("Instagram", "https://www.instagram.com"),
        "linkedin": ("LinkedIn", "https://www.linkedin.com"), "twitter": ("X", "https://x.com"), "x": ("X", "https://x.com"),
        "chatgpt": ("ChatGPT", "https://chatgpt.com"), "claude": ("Claude", "https://claude.ai"),
        "outlook": ("Outlook", "https://outlook.live.com"), "spotify": ("Spotify", "https://open.spotify.com"),
        "weather": ("the weather", "https://www.google.com/search?q=weather"), "news": ("Google News", "https://news.google.com"),
    ]

    public static func parse(_ question: String) -> WebAction? {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
            .replacingOccurrences(of: "’", with: "'")
        let lead = #"^(?i)(?:hey wisp,? |wisp,? )?(?:can you |could you |please |go ahead and |would you )*"#
        if let r = q.range(of: lead, options: .regularExpression) { q = String(q[r.upperBound...]) }
        q = q.replacingOccurrences(of: #"(?i)\s+(?:for me|please)$"#, with: "", options: .regularExpression)
        // "Open (up) my browser and …" / "go online and …": the browser part is implied.
        q = q.replacingOccurrences(of: #"(?i)^(?:open(?: up)? (?:the |my )?(?:web )?browser|go online|get online) and (?=(?:open|go to|search|look|find|google|pull up))"#,
                                   with: "", options: .regularExpression)
        let lower = q.lowercased()

        // On a site: "open Instagram and search for X", "search YouTube for X", "search for X on Amazon".
        let sitePatterns = [
            #"^(?:open(?: up)?|go to|pull up) (?:the )?(?<s>[a-z ]+?)(?: website| site| app)? and (?:search|look)(?: up)?(?: for)? (?<q>.+)$"#,
            #"^search (?:on )?(?<s>[a-z ]+?) for (?<q>.+)$"#,
            #"^(?:search|look) (?:up )?(?:for )?(?<q>.+?) on (?<s>[a-z ]+?)$"#,
            #"^find (?<q>.+?) on (?<s>[a-z ]+?)$"#,
        ]
        for p in sitePatterns {
            guard let regex = try? NSRegularExpression(pattern: p),
                  let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let rs = Range(m.range(withName: "s"), in: lower), let rq = Range(m.range(withName: "q"), in: q) else { continue }
            if let action = siteSearch(site: String(lower[rs]), query: String(q[rq]).trimmingCharacters(in: .whitespaces)) { return action }
        }

        // Search: "search (online|the web|google) for X", "go online and search (for) X", "google X", "look up X online".
        let searchPatterns = [
            #"^(?:go online and |open (?:the |my )?browser and |open (?:safari|chrome) and )?(?:search|look)(?: up)? (?:online |the web |the internet |google |on google |on the web |on the internet )?for (?<q>.+)$"#,
            #"^(?:go online and |open (?:the |my )?browser and )search(?: up)? (?<q>.+)$"#,
            #"^search (?:online|the web|the internet|google|on google) (?:for )?(?<q>.+)$"#,
            #"^google (?<q>.+)$"#,
            #"^look up (?<q>.+?) (?:online|on the web|on the internet|on google)$"#,
            #"^find (?<q>.+?) (?:online|on the web|on the internet|on google)$"#,
        ]
        for p in searchPatterns {
            guard let regex = try? NSRegularExpression(pattern: p),
                  let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let r = Range(m.range(withName: "q"), in: q) else { continue }
            let query = String(q[r]).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"“”")))
            // "search for the export button" is about the screen, not the web.
            let ql = " " + query.lowercased() + " "
            let onScreen = [" this ", " it ", " that ", " button ", " menu ", " icon ", " setting ", " settings ", " tab ", " on screen ",
                            " on the screen ", " on my screen ", " in this app ", " on this page ", " here "]
            if query.isEmpty || onScreen.contains(where: { ql.contains($0) }) { return nil }
            return .search(query)
        }

        // Open a site: "open youtube", "go to youtube.com", "take me to gmail".
        if let regex = try? NSRegularExpression(pattern: #"^(?:open(?: up)?|go to|take me to|pull up|launch) (?:the )?(?<s>[a-z0-9 .\-]+?)(?: website| site| in (?:the |my )?browser| in safari| in chrome)?$"#),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(m.range(withName: "s"), in: lower) {
            let s = String(lower[r]).trimmingCharacters(in: .whitespaces)
            if let (name, url) = sites[s], let u = URL(string: url) { return .open(name: name, url: u) }
            // A domain: "go to apple.com"
            if s.range(of: #"^[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}$"#, options: .regularExpression) != nil,
               let u = URL(string: "https://" + s) { return .open(name: s, url: u) }
        }
        return nil
    }

    /// The page to open.
    public var url: URL {
        switch self {
        case .open(_, let url), .siteSearch(_, _, let url): return url
        case .search(let query):
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            return c.url!
        }
    }

    /// What appears typed into the address bar.
    public var typedText: String {
        switch self {
        case .search(let q): return q
        case .open(_, let url): return url.host ?? url.absoluteString
        case .siteSearch(let name, let q, _): return (Self.siteSearches.first { $0.value.0 == name }?.value.1 ?? name) + "  " + q
        }
    }

    public var spokenResult: String {
        switch self {
        case .search(let q): return "Here are the results for \(q)."
        case .open(let name, _): return "Here's \(name)."
        case .siteSearch(let name, let q, _): return "Here's \(name) with results for \(q)."
        }
    }
}
