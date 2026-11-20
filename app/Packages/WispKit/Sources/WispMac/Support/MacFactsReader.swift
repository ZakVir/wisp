import Foundation
import IOKit.ps
import WispCore

/// Reads the answers to `MacFacts` questions from the system (nothing is sent anywhere).
public enum MacFactsReader {
    public static func answer(_ question: MacFacts.Question) -> String {
        switch question {
        case .storage:
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity, total > 0 else {
                return "I couldn't read your disk space just now."
            }
            var text = "You have \(MacFacts.bytes(free)) free, out of \(MacFacts.bytes(Int64(total)))."
            if Double(free) / Double(total) < 0.1 { text += " That's getting low; emptying the Trash and removing big downloads helps." }
            return text
        case .battery:
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
                  let source = list.first,
                  let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else {
                return "This Mac doesn't have a battery."
            }
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return "Your battery is at \(percent)%" + (charging ? ", and charging." : plugged ? ", plugged in." : ".")
        case .macOSVersion:
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "You're on macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)." : ".")
        case .memory:
            return "This Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB of memory."
        case .uptime:
            return "Your Mac has been on for \(MacFacts.duration(ProcessInfo.processInfo.systemUptime)) since it last restarted."
        }
    }
}
