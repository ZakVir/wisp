// Dev tool: hold a modifier chord for N seconds by posting real key events (like a person pressing them).
// Build: swiftc -O tools/chord.swift -o build/tools/chord
// Usage: build/tools/chord [seconds=2] [keys=control,option] [--press-other-key]
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 2 : 2
let names = (args.count > 2 ? args[2] : "control,option").split(separator: ",").map(String.init)
let pressOther = args.contains("--press-other-key")
// --at=x,y parks the pointer there (global top-left coordinates) for the duration, then restores it.
let at: CGPoint? = args.first { $0.hasPrefix("--at=") }.flatMap {
    let p = $0.dropFirst(5).split(separator: ",").compactMap { Double($0) }
    return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : nil
}
let originalPointer = CGEvent(source: nil)?.location
if let at { CGWarpMouseCursorPosition(at); usleep(100_000) }
let table: [String: (CGKeyCode, CGEventFlags)] = [
    "control": (0x3B, .maskControl), "option": (0x3A, .maskAlternate), "command": (0x37, .maskCommand),
    "shift": (0x38, .maskShift), "fn": (0x3F, .maskSecondaryFn),
]
let source = CGEventSource(stateID: .hidSystemState)
var flags: CGEventFlags = []
func post(_ key: CGKeyCode, down: Bool) {
    let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
    e.type = .flagsChanged
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
for name in names {
    guard let (key, flag) = table[name] else { continue }
    flags.insert(flag); post(key, down: true); usleep(30_000)
}
if pressOther {
    usleep(300_000)
    let d = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: true)!; d.flags = flags; d.post(tap: .cghidEventTap)
    let u = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: false)!; u.flags = flags; u.post(tap: .cghidEventTap)
}
usleep(useconds_t(seconds * 1_000_000))
for name in names.reversed() {
    guard let (key, flag) = table[name] else { continue }
    flags.remove(flag); post(key, down: false); usleep(30_000)
}
if let at, let originalPointer { _ = at; usleep(300_000); CGWarpMouseCursorPosition(originalPointer) }
