import Foundation

/// Arithmetic and unit conversions answered on the Mac, exactly and instantly ("what's 15% of 80?", "convert 5
/// miles to kilometers"). A small parser of its own: nothing is ever evaluated as code.
public enum QuickMath {
    /// The spoken answer, or nil when the question isn't plain arithmetic or a conversion.
    public static func answer(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        var q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        for lead in ["hey wisp ", "wisp ", "please ", "can you tell me ", "tell me ", "quick question "] where q.hasPrefix(lead) {
            q = String(q.dropFirst(lead.count))
        }
        q = digitsForNumberWords(q)
        if let tip = tip(q) { return tip }
        if let days = daysUntil(q, now: now, calendar: calendar) { return days }
        if let conversion = convert(q) { return conversion }
        for lead in ["what's ", "what is ", "whats ", "calculate ", "compute ", "how much is "] where q.hasPrefix(lead) {
            let expr = String(q.dropFirst(lead.count))
            if let (value, spoken) = evaluate(expr) { return "\(spoken) is \(format(value))." }
        }
        return nil
    }

    /// "twenty five" → "25", "two hundred and ten" → "210", "three point five" → "3.5" (speech often spells numbers).
    static func digitsForNumberWords(_ text: String) -> String {
        let small: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
                                    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            var total = 0, current = 0, used = 0
            var j = i
            while j < words.count {
                let w = words[j].replacingOccurrences(of: "-", with: " ")
                let parts = w.split(separator: " ").map(String.init)
                if parts.count > 1, parts.allSatisfy({ small[$0] != nil }) { current += parts.compactMap { small[$0] }.reduce(0, +); used += 1; j += 1; continue }
                if let v = small[w] { current += v; used += 1; j += 1; continue }
                if w == "hundred", used > 0 { current *= 100; j += 1; continue }
                if w == "thousand", used > 0 { total += current * 1000; current = 0; j += 1; continue }
                if w == "and", used > 0, j + 1 < words.count, small[words[j + 1]] != nil { j += 1; continue }
                break
            }
            if used > 0 {
                var number = String(total + current)
                // "three point five"
                if j + 1 < words.count, words[j] == "point", let d = small[words[j + 1]], d < 10 { number += ".\(d)"; j += 2 }
                out.append(number)
                i = j
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    // MARK: Arithmetic

    /// Evaluates words-and-symbols arithmetic; returns the value and how the question is said back.
    static func evaluate(_ text: String) -> (Double, String)? {
        var t = " " + text + " "
        // "15% of 80" / "15 percent of 80" → (15/100*80)
        if let m = t.range(of: #" (\d+(\.\d+)?) ?(%|percent) of (\d+(\.\d+)?) "#, options: .regularExpression) {
            let parts = t[m].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "percent", with: "%")
                .replacingOccurrences(of: " ", with: "").components(separatedBy: "%of")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), t.trimmingCharacters(in: .whitespaces).count == t[m].trimmingCharacters(in: .whitespaces).count {
                return (a / 100 * b, "\(clean(parts[0]))% of \(clean(parts[1]))")
            }
        }
        let words: [(String, String)] = [
            (" multiplied by ", " * "), (" divided by ", " / "), (" to the power of ", " ^ "), (" times ", " * "),
            (" plus ", " + "), (" minus ", " - "), (" over ", " / "), (" x ", " * "), (" × ", " * "), (" ÷ ", " / "),
            (" squared ", " ^ 2 "), (" cubed ", " ^ 3 "), (" and ", " + "),
        ]
        for (word, symbol) in words { t = t.replacingOccurrences(of: word, with: symbol) }
        t = t.replacingOccurrences(of: ",", with: "")
        // "square root of 81" → sqrt as a unary prefix
        t = t.replacingOccurrences(of: "the square root of", with: "√").replacingOccurrences(of: "square root of", with: "√")
        let expr = t.trimmingCharacters(in: .whitespaces)
        guard expr.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^√")) != nil,
              expr.allSatisfy({ "0123456789.+-*/^()√ ".contains($0) }) else { return nil }
        var parser = Parser(Array(expr.filter { $0 != " " }))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        let spoken = expr.replacingOccurrences(of: "*", with: "times").replacingOccurrences(of: "/", with: "divided by")
            .replacingOccurrences(of: "^", with: "to the power of").replacingOccurrences(of: "√", with: "the square root of ")
            .replacingOccurrences(of: "+", with: "plus").replacingOccurrences(of: " -", with: " minus")
        return (value, spoken.replacingOccurrences(of: "  ", with: " "))
    }

    private struct Parser {
        let s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }
        var atEnd: Bool { i == s.count }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while i < s.count, s[i] == "+" || s[i] == "-" {
                let op = s[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < s.count, s[i] == "*" || s[i] == "/" {
                let op = s[i]; i += 1
                guard let r = power() else { return nil }
                if op == "/" { guard r != 0 else { return nil }; v /= r } else { v *= r }
            }
            return v
        }
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < s.count, s[i] == "^" {
                i += 1
                guard let e = power(), abs(e) <= 64 else { return nil }
                return pow(base, e)
            }
            return base
        }
        mutating func unary() -> Double? {
            if i < s.count, s[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < s.count, s[i] == "√" { i += 1; guard let v = unary(), v >= 0 else { return nil }; return v.squareRoot() }
            return primary()
        }
        mutating func primary() -> Double? {
            if i < s.count, s[i] == "(" {
                i += 1
                guard let v = expression(), i < s.count, s[i] == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while i < s.count, s[i].isNumber || s[i] == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(s[start..<i]))
        }
    }

    // MARK: Tips and day counts

    /// "What's a 20% tip on 45 dollars?", "tip on $80" (18% when no percent is said).
    static func tip(_ q: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(?:what(?:'s| is) )?(?:an? )?(?:(\d+(?:\.\d+)?) ?(?:%|percent) )?tip (?:on|for) \$?(\d+(?:\.\d+)?)(?: dollars| bucks)?$"#),
              let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let rb = Range(m.range(at: 2), in: q), let bill = Double(q[rb]) else { return nil }
        let percent = Range(m.range(at: 1), in: q).flatMap { Double(q[$0]) } ?? 18
        let t = bill * percent / 100
        let p = format(percent)
        let article = p.hasPrefix("8") || p == "11" || p == "18" || p.hasPrefix("11.") || p.hasPrefix("18.") ? "An" : "A"
        return String(format: "%@ %@%% tip on $%@ is $%.2f, for a total of $%.2f.", article, p, format(bill), t, bill + t)
    }

    /// "How many days until December 25?", "…until Christmas / New Year's / Halloween / Valentine's Day".
    static func daysUntil(_ q: String, now: Date, calendar: Calendar) -> String? {
        guard let r = q.range(of: #"^how many days (?:until|till|to|before) "#, options: .regularExpression) else { return nil }
        let target = String(q[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let holidays: [String: (Int, Int)] = ["christmas": (12, 25), "christmas day": (12, 25), "new year's": (1, 1), "new years": (1, 1),
                                              "new year's day": (1, 1), "new year": (1, 1), "halloween": (10, 31),
                                              "valentine's day": (2, 14), "valentines day": (2, 14), "independence day": (7, 4),
                                              "the fourth of july": (7, 4), "july 4th": (7, 4)]
        var month = 0, day = 0
        if let h = holidays[target] { (month, day) = h } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone   // read the date in the same zone the month and day are taken from below
            let cleaned = target.replacingOccurrences(of: #"(\d+)(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
            var parsed: Date?
            for format in ["MMMM d", "MMM d", "d MMMM", "MMMM d yyyy", "MMMM d, yyyy"] {
                f.dateFormat = format
                if let d = f.date(from: cleaned) { parsed = d; break }
            }
            guard let parsed else { return nil }
            month = calendar.component(.month, from: parsed); day = calendar.component(.day, from: parsed)
        }
        let today = calendar.startOfDay(for: now)
        guard var target = calendar.nextDate(after: today.addingTimeInterval(-1), matching: DateComponents(month: month, day: day), matchingPolicy: .nextTime)
        else { return nil }
        target = calendar.startOfDay(for: target)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        if days == 0 { return "That's today!" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; f.timeZone = calendar.timeZone
        return "\(days) day\(days == 1 ? "" : "s"), until \(f.string(from: target))."
    }

    // MARK: Conversions

    private struct NamedUnit {
        let names: [String]; let unit: Dimension; let say: String
        init(_ names: [String], _ unit: Dimension, _ say: String) { self.names = names; self.unit = unit; self.say = say }
    }

    private static let units: [NamedUnit] = {
        var list: [NamedUnit] = []
        list.append(NamedUnit(["km", "kilometer", "kilometers", "kilometre", "kilometres"], UnitLength.kilometers, "kilometers"))
        list.append(NamedUnit(["m", "meter", "meters", "metre", "metres"], UnitLength.meters, "meters"))
        list.append(NamedUnit(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], UnitLength.centimeters, "centimeters"))
        list.append(NamedUnit(["mm", "millimeter", "millimeters"], UnitLength.millimeters, "millimeters"))
        list.append(NamedUnit(["mile", "miles", "mi"], UnitLength.miles, "miles"))
        list.append(NamedUnit(["foot", "feet", "ft"], UnitLength.feet, "feet"))
        list.append(NamedUnit(["inch", "inches", "in"], UnitLength.inches, "inches"))
        list.append(NamedUnit(["yard", "yards", "yd"], UnitLength.yards, "yards"))
        list.append(NamedUnit(["kg", "kilo", "kilos", "kilogram", "kilograms"], UnitMass.kilograms, "kilograms"))
        list.append(NamedUnit(["g", "gram", "grams"], UnitMass.grams, "grams"))
        list.append(NamedUnit(["pound", "pounds", "lb", "lbs"], UnitMass.pounds, "pounds"))
        list.append(NamedUnit(["ounce", "ounces", "oz"], UnitMass.ounces, "ounces"))
        list.append(NamedUnit(["stone", "stones"], UnitMass.stones, "stone"))
        list.append(NamedUnit(["celsius", "c", "degrees celsius", "centigrade"], UnitTemperature.celsius, "degrees Celsius"))
        list.append(NamedUnit(["fahrenheit", "f", "degrees fahrenheit"], UnitTemperature.fahrenheit, "degrees Fahrenheit"))
        list.append(NamedUnit(["liter", "liters", "litre", "litres", "l"], UnitVolume.liters, "liters"))
        list.append(NamedUnit(["milliliter", "milliliters", "ml"], UnitVolume.milliliters, "milliliters"))
        list.append(NamedUnit(["cup", "cups"], UnitVolume.cups, "cups"))
        list.append(NamedUnit(["gallon", "gallons", "gal"], UnitVolume.gallons, "gallons"))
        list.append(NamedUnit(["fluid ounce", "fluid ounces", "fl oz"], UnitVolume.fluidOunces, "fluid ounces"))
        list.append(NamedUnit(["tablespoon", "tablespoons", "tbsp"], UnitVolume.tablespoons, "tablespoons"))
        list.append(NamedUnit(["teaspoon", "teaspoons", "tsp"], UnitVolume.teaspoons, "teaspoons"))
        list.append(NamedUnit(["mph", "miles per hour"], UnitSpeed.milesPerHour, "miles per hour"))
        list.append(NamedUnit(["km/h", "kph", "kilometers per hour", "kilometres per hour"], UnitSpeed.kilometersPerHour, "kilometers per hour"))
        return list
    }()

    private static func unit(_ name: String) -> (Dimension, String)? {
        let n = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "degrees ", with: "")
        let key = units.first { $0.names.contains(n) || $0.names.contains(name.trimmingCharacters(in: .whitespaces)) }
        return key.map { ($0.unit, $0.say) }
    }

    static func convert(_ q: String) -> String? {
        let number = #"(\d+(?:\.\d+)?|a|an|one)"#
        let unitName = #"([a-z/ ]+?)"#
        let first: String = #"^(?:convert |what's |what is |how much is )?"# + number + " " + unitName
        let forward: String = first + #" (?:to|in|into) "# + unitName + "$"
        let howMany: String = #"^how many "# + unitName + #" (?:are )?(?:in|is) "# + number + " " + unitName + "$"
        let patterns: [String] = [forward, howMany]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), m.numberOfRanges == 4,
                  let r1 = Range(m.range(at: 1), in: q), let r2 = Range(m.range(at: 2), in: q), let r3 = Range(m.range(at: 3), in: q) else { continue }
            let a = String(q[r1]), b = String(q[r2]), c = String(q[r3])
            let amountText: String, fromName: String, toName: String
            if index == 0 { amountText = a; fromName = b; toName = c } else { amountText = b; fromName = c; toName = a }
            let amount = Double(amountText) ?? 1
            guard let (from, fromSay) = unit(fromName), let (to, toSay) = unit(toName), type(of: from) == type(of: to) else { continue }
            let result = Measurement(value: amount, unit: from).converted(to: to).value
            return "\(format(amount)) \(amount == 1 ? singular(fromSay) : fromSay) is \(format(result)) \(result == 1 ? singular(toSay) : toSay)."
        }
        return nil
    }

    /// "pounds" → "pound", "feet" → "foot", "degrees Celsius" → "degree Celsius".
    static func singular(_ say: String) -> String {
        let special = ["feet": "foot", "inches": "inch", "stone": "stone", "miles per hour": "mile per hour",
                       "kilometers per hour": "kilometer per hour"]
        if let s = special[say] { return s }
        if say.hasPrefix("degrees ") { return "degree " + say.dropFirst(8) }
        return say.hasSuffix("s") ? String(say.dropLast()) : say
    }

    // MARK: Formatting

    static func format(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9, abs(v) < 1e15 { return String(Int64(v.rounded())) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumSignificantDigits = 6
        f.usesSignificantDigits = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private static func clean(_ s: String) -> String { format(Double(s) ?? 0) }
}
