import Foundation

/// "Pause Wisp": shortcuts do nothing until a time (or until resumed).
public enum PauseState {
    public enum Length: String, CaseIterable, Sendable {
        case hour, tomorrow, indefinitely

        public var title: String {
            switch self {
            case .hour: return "For 1 Hour"
            case .tomorrow: return "Until Tomorrow"
            case .indefinitely: return "Until I Resume"
            }
        }
    }

    /// When a pause of `length` started at `now` ends (tomorrow = 6 AM the next day); `.distantFuture` for indefinitely.
    public static func end(of length: Length, from now: Date, calendar: Calendar = .current) -> Date {
        switch length {
        case .hour: return now.addingTimeInterval(3600)
        case .indefinitely: return .distantFuture
        case .tomorrow:
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            return calendar.date(byAdding: .hour, value: 6, to: next) ?? next
        }
    }

    /// "Paused until 3:40 PM", "Paused until tomorrow", "Paused".
    public static func description(until end: Date, now: Date, calendar: Calendar = .current) -> String {
        if end == .distantFuture { return "Paused" }
        let time = end.formatted(date: .omitted, time: .shortened)
        return calendar.isDate(end, inSameDayAs: now) ? "Paused until \(time)" : "Paused until tomorrow, \(time)"
    }
}
