import Foundation

/// "What time is it?", "what's the date?", "what time is it in Tokyo?": answered from the Mac's clock.
public enum TimeAnswer {
    private static let aliases: [String: String] = [
        "new york": "America/New_York", "nyc": "America/New_York", "boston": "America/New_York", "miami": "America/New_York",
        "washington": "America/New_York", "atlanta": "America/New_York", "toronto": "America/Toronto",
        "chicago": "America/Chicago", "dallas": "America/Chicago", "austin": "America/Chicago", "houston": "America/Chicago",
        "denver": "America/Denver", "phoenix": "America/Phoenix", "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles", "vancouver": "America/Vancouver",
        "honolulu": "Pacific/Honolulu", "hawaii": "Pacific/Honolulu", "mexico city": "America/Mexico_City",
        "sao paulo": "America/Sao_Paulo", "são paulo": "America/Sao_Paulo", "buenos aires": "America/Argentina/Buenos_Aires",
        "london": "Europe/London", "uk": "Europe/London", "england": "Europe/London", "dublin": "Europe/Dublin",
        "paris": "Europe/Paris", "france": "Europe/Paris", "berlin": "Europe/Berlin", "germany": "Europe/Berlin",
        "madrid": "Europe/Madrid", "spain": "Europe/Madrid", "rome": "Europe/Rome", "italy": "Europe/Rome",
        "amsterdam": "Europe/Amsterdam", "moscow": "Europe/Moscow", "istanbul": "Europe/Istanbul", "cairo": "Africa/Cairo",
        "lagos": "Africa/Lagos", "nairobi": "Africa/Nairobi", "johannesburg": "Africa/Johannesburg", "dubai": "Asia/Dubai",
        "karachi": "Asia/Karachi", "pakistan": "Asia/Karachi", "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
        "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bangkok": "Asia/Bangkok",
        "singapore": "Asia/Singapore", "jakarta": "Asia/Jakarta", "manila": "Asia/Manila", "hong kong": "Asia/Hong_Kong",
        "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai", "china": "Asia/Shanghai", "seoul": "Asia/Seoul",
        "korea": "Asia/Seoul", "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "sydney": "Australia/Sydney",
        "melbourne": "Australia/Melbourne", "perth": "Australia/Perth", "auckland": "Pacific/Auckland", "new zealand": "Pacific/Auckland",
    ]

    /// The spoken answer, or nil when the question isn't about the time or date.
    public static func answer(_ question: String, now: Date = Date(), here: TimeZone = .current) -> String? {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        let time = #"^(?:hey wisp,? |wisp,? )?(?:what time is it|what's the time|what is the time|what's the time now|what time is it now|time check)"#
        if let r = q.range(of: time + #"(?: right now| now)?(?: in (?<place>[a-zãõ ]+))?$"#, options: .regularExpression), r.lowerBound == q.startIndex {
            let place = q.components(separatedBy: " in ").count > 1 ? q.components(separatedBy: " in ").last : nil
            var zone = here
            var whereText = ""
            if let place {
                guard let found = zoneFor(place) else { return nil } // unknown place: let the AI handle it
                zone = found
                whereText = " in " + place.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
            let f = DateFormatter()
            f.timeZone = zone
            f.dateFormat = "h:mm a"
            var text = "It's \(f.string(from: now))\(whereText)"
            if zone.identifier != here.identifier {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                var calHere = Calendar(identifier: .gregorian)
                calHere.timeZone = here
                let dayThere = cal.component(.day, from: now), dayHere = calHere.component(.day, from: now)
                if dayThere != dayHere {
                    let wf = DateFormatter(); wf.timeZone = zone; wf.dateFormat = "EEEE"
                    text += ", \(wf.string(from: now))"
                }
            }
            return text + "."
        }
        if q.range(of: #"^(?:what's|what is) (?:the |today's )?date(?: today)?$|^what day is it(?: today)?$|^what's today$|^what is today$"#, options: .regularExpression) != nil {
            let f = DateFormatter()
            f.timeZone = here
            f.dateFormat = "EEEE, MMMM d, yyyy"
            return "It's \(f.string(from: now))."
        }
        return nil
    }

    static func zoneFor(_ place: String) -> TimeZone? {
        let p = place.trimmingCharacters(in: .whitespaces)
        if let id = aliases[p] { return TimeZone(identifier: id) }
        let key = p.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased().hasSuffix("/" + key) }) { return TimeZone(identifier: id) }
        return nil
    }
}
