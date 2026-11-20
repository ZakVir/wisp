import Foundation

/// Questions about the Mac itself, answered from the system ("how much storage do I have left?").
public enum MacFacts {
    public enum Question: Equatable, Sendable { case storage, battery, macOSVersion, memory, uptime }

    public static func parse(_ question: String) -> Question? {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        func m(_ p: String) -> Bool { q.range(of: p, options: .regularExpression) != nil }
        if m(#"^(how much|how much free|what's my|what is my|how much disk|how much hard drive) (storage|space|disk space|free space|room)( do i have)?( left| free| available)?( on (my|this) (mac|computer|disk|drive))?$"#)
            || m(#"^(is my|how full is my) (disk|drive|storage|mac|hard drive)( full)?$"#) { return .storage }
        if m(#"^(what's|what is|how much is|how's|how is) (my|the) battery( at| level| life| percentage)?$|^how much battery( do i have)?( left)?$|^battery( level)?$|^am i charging$|^is (my mac|it) charging$"#) { return .battery }
        if m(#"^(what|which) (version of )?(macos|mac os|os x)( version)?( (do i have|am i (on|running)|is this))?$|^what macos (do i have|am i (on|running))$|^what version of macos (do i have|am i (on|running)|is this)$"#) { return .macOSVersion }
        if m(#"^how much (memory|ram)( does (my|this) (mac|computer) have| do i have)?$|^what's my (memory|ram)$"#) { return .memory }
        if m(#"^how long has (my|this) (mac|computer) been (on|running|up)$|^when did i (last )?restart( my mac)?$|^uptime$"#) { return .uptime }
        return nil
    }

    /// "245 GB", "26.4 GB", "512 MB".
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useGB, .useMB, .useTB]
        return f.string(fromByteCount: n)
    }

    /// "3 days and 4 hours", "2 hours and 5 minutes", "12 minutes".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        func unit(_ v: Int, _ name: String) -> String { "\(v) \(name)\(v == 1 ? "" : "s")" }
        if d > 0 { return h > 0 ? "\(unit(d, "day")) and \(unit(h, "hour"))" : unit(d, "day") }
        if h > 0 { return m > 0 ? "\(unit(h, "hour")) and \(unit(m, "minute"))" : unit(h, "hour") }
        return unit(max(m, 1), "minute")
    }
}
