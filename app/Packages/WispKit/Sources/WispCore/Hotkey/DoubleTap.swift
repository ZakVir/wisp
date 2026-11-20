import Foundation

/// Recognises a double tap of one modifier key on its own (for example Control, Control) with nothing else
/// pressed in between. Pure logic, fed with modifier changes and key presses.
public struct DoubleTapDetector: Sendable {
    public var key: ModifierSet
    /// A tap is a press and release shorter than this.
    public var maxTap: TimeInterval = 0.3
    /// The second press must start within this long after the first release.
    public var maxGap: TimeInterval = 0.4

    private var pressedAt: TimeInterval?
    private var lastTapEnd: TimeInterval?
    private var spoiled = false

    public init(key: ModifierSet) { self.key = key }

    /// Feed every modifier change. Returns true when this change completes a double tap.
    public mutating func modifiersChanged(_ mods: ModifierSet, at time: TimeInterval) -> Bool {
        if mods == key {
            if pressedAt == nil {
                pressedAt = time
                spoiled = false
                if let end = lastTapEnd, time - end > maxGap { lastTapEnd = nil }
            }
            return false
        }
        if mods.isEmpty, let start = pressedAt {
            pressedAt = nil
            guard !spoiled, time - start <= maxTap else { lastTapEnd = nil; return false }
            if lastTapEnd != nil {
                lastTapEnd = nil
                return true
            }
            lastTapEnd = time
            return false
        }
        // Another modifier joined (a shortcut such as Control + Option): not a tap.
        if !mods.isEmpty { spoiled = true; lastTapEnd = nil }
        if mods.isEmpty { pressedAt = nil }
        return false
    }

    /// Any other key pressed: whatever was going on is a keyboard shortcut, not a tap.
    public mutating func keyPressed() {
        spoiled = true
        lastTapEnd = nil
    }
}
