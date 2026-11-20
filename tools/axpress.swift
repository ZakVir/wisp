// Dev tool: press a button by title (or list controls) in Wisp's windows via the Accessibility API.
// Build: swiftc -O tools/axpress.swift -o build/tools/axpress
// Usage: build/tools/axpress "<Button title>"   |   build/tools/axpress --list
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
}
func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
    guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
    let array = value as! CFArray
    return (0..<CFArrayGetCount(array)).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self) }
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "--list"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zakvirani.wisp").first else {
    print("Wisp is not running"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1.0)
var visited = 0
var stack: [(AXUIElement, Int)] = children(root, kAXWindowsAttribute).map { ($0, 0) }
let interesting: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXStaticText"]
while let (element, depth) = stack.popLast() {
    visited += 1
    if visited > 4000 || depth > 40 { continue }
    let role = string(element, kAXRoleAttribute)
    let title = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), (attribute(element, kAXValueAttribute) as? String) ?? ""].first { !$0.isEmpty } ?? ""
    if target == "--list" {
        if interesting.contains(role) { print(String(repeating: "  ", count: depth) + role + " " + title) }
    } else if ["AXButton", "AXRadioButton", "AXTab", "AXCheckBox"].contains(role) && title == target {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        print(result == .success ? "pressed \(target)" : "press failed \(result.rawValue)")
        exit(result == .success ? 0 : 3)
    }
    stack.append(contentsOf: children(element).reversed().map { ($0, depth + 1) })
}
if target != "--list" { print("button not found: \(target)"); exit(2) }
