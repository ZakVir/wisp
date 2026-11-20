// Dev tool: set the value of the first text field (or secure field) in Wisp's windows via Accessibility.
// Build: swiftc -O tools/axset.swift -o build/tools/axset
// Usage: build/tools/axset "<text>"
import AppKit
import ApplicationServices

func attribute(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func children(_ e: AXUIElement, _ n: String = kAXChildrenAttribute) -> [AXUIElement] {
    guard let v = attribute(e, n), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
    let a = v as! CFArray
    return (0..<CFArrayGetCount(a)).map { unsafeBitCast(CFArrayGetValueAtIndex(a, $0), to: AXUIElement.self) }
}
guard CommandLine.arguments.count > 1, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zakvirani.wisp").first else { exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
var stack = children(root, kAXWindowsAttribute)
while let e = stack.popLast() {
    let role = (attribute(e, kAXRoleAttribute) as? String) ?? ""
    if role == "AXTextField" || role == "AXSecureTextField" {
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, CommandLine.arguments[1] as CFString)
        print(r == .success ? "set" : "failed \(r.rawValue)")
        exit(r == .success ? 0 : 2)
    }
    stack += children(e)
}
print("no text field"); exit(3)
