// Dev tool for the pointing golden set: dump the front window of an app and its labelled controls as JSON.
// Build: swiftc -O tools/ax_dump.swift -o build/tools/ax_dump
// Usage: build/tools/ax_dump <bundle id>
// Prints {"windowID", "window": [x, y, w, h], "screen": [w, h], "scale", "elements": [{"role", "title", "frame"}]}
// Frames are global points with a top-left origin (the Accessibility convention).
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }
func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
    let array = value as! CFArray
    return (0..<CFArrayGetCount(array)).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self) }
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

guard CommandLine.arguments.count > 1,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first else {
    print("{}"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2.0)
guard let window = (attribute(root, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }) ?? children(root, kAXWindowsAttribute).first,
      let wf = frame(window) else { print("{}"); exit(2) }

// Match the AX window to a CGWindow (same owner, same bounds) for `screencapture -l`.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var windowID = 0
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let b = w[kCGWindowBounds as String] as? [String: Double],
       abs((b["X"] ?? 0) - wf.minX) < 2, abs((b["Y"] ?? 0) - wf.minY) < 2, abs((b["Width"] ?? 0) - wf.width) < 2 {
        windowID = w[kCGWindowNumber as String] as? Int ?? 0
    }
}

let roles: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXTab", "AXTextField", "AXSearchField"]
var out: [[String: Any]] = []
var stack: [(AXUIElement, Int)] = [(window, 0)]
var visited = 0
while let (element, depth) = stack.popLast() {
    visited += 1
    if visited > 5000 || depth > 40 { continue }
    let role = string(element, kAXRoleAttribute)
    let subrole = string(element, kAXSubroleAttribute)
    if roles.contains(role), !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole),
       let f = frame(element), f.width >= 8, f.height >= 8, wf.contains(f.insetBy(dx: 1, dy: 1)) {
        let title = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
                     string(element, kAXHelpAttribute)].first { !$0.isEmpty } ?? ""
        if !title.isEmpty {
            out.append(["role": role, "title": title, "frame": [f.minX, f.minY, f.width, f.height]])
        }
    }
    stack += children(element).map { ($0, depth + 1) }
}
let screen = NSScreen.screens.first!
let json: [String: Any] = ["windowID": windowID, "window": [wf.minX, wf.minY, wf.width, wf.height],
                           "screen": [screen.frame.width, screen.frame.height], "scale": screen.backingScaleFactor, "elements": out]
print(String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)
