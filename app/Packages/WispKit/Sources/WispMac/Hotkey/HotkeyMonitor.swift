import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os
import WispCore

/// Watches the keyboard for the push-to-talk chord with a listen-only event tap (needs Input Monitoring).
///
/// The tap runs on its own thread and run loop so a busy main thread can never delay or disable it.
/// It only ever looks at modifier flags, whether *some* key went down, and whether that key was Escape (to stop an
/// answer); other key codes and characters are never read, stored or logged.
public final class HotkeyMonitor: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case stopped
        case running
        /// The tap could not be created: Input Monitoring is off (or blocked by another security tool).
        case tapUnavailable
    }

    /// Delivered on the main queue.
    public var onEvent: (@MainActor (ChordEvent) -> Void)?
    /// Escape pressed on its own (no modifiers), delivered on the main queue. Escape still reaches the front app.
    public var onEscape: (@MainActor () -> Void)?
    /// The chosen key tapped twice on its own (type a question), delivered on the main queue.
    public var onDoubleTap: (@MainActor () -> Void)?
    /// Every modifier change, delivered on the main queue (for the shortcut test and recorder UI).
    public var onModifiersChanged: (@MainActor (ModifierSet) -> Void)?

    public private(set) var status: Status = .stopped

    // Touched only on the tap thread.
    private var machine: ChordStateMachine
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var tickTimer: CFRunLoopTimer?
    private var lastModifiers: ModifierSet = []
    /// Set when key events may have been missed (tap disabled, secure input); cleared by the next real event.
    private var eventsMayBeMissing = false
    private let startLock = NSCondition()
    private var startResult: Bool?
    /// The latest requested chord, readable from any thread; the tap thread builds its machine from it.
    private let desiredChord: OSAllocatedUnfairLock<Chord>
    /// Whether a double tap of Control is listened for (readable from any thread).
    private let doubleTapEnabled = OSAllocatedUnfairLock(initialState: false)
    private var doubleTap = DoubleTapDetector(key: .control) // tap thread only
    private let doubleTapKey = OSAllocatedUnfairLock(initialState: ModifierSet.control)

    public init(chord: Chord) {
        machine = ChordStateMachine(chord: chord)
        desiredChord = OSAllocatedUnfairLock(initialState: chord)
    }

    /// Creates the tap and starts its thread. Returns false when Input Monitoring is not usable.
    @discardableResult
    public func start() -> Bool {
        if status == .running { return true }
        startLock.lock()
        startResult = nil
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "com.zakvirani.wisp.hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        while startResult == nil { startLock.wait() }
        let ok = startResult ?? false
        startLock.unlock()
        status = ok ? .running : .tapUnavailable
        Log.hotkey.info("hotkey monitor start: \(ok ? "running" : "tap unavailable", privacy: .public)")
        return ok
    }

    public func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            if let timer = self.tickTimer { CFRunLoopTimerInvalidate(timer) }
            self.tap = nil
            self.source = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
        status = .stopped
    }

    /// Changes the chord without recreating the tap. Works before `start()` too (the tap thread reads the
    /// latest chord when it starts). No-op when the chord is unchanged; otherwise a turn in progress is cancelled.
    public func update(chord: Chord) {
        let changed = desiredChord.withLock { current -> Bool in
            guard current != chord else { return false }
            current = chord
            return true
        }
        guard changed else { return }
        perform { monitor in
            if monitor.machine.isListening {
                monitor.emit(.cancelled(reason: .interrupted))
            }
            monitor.machine.chord = chord
            monitor.machine.reset()
        }
    }

    /// Turns the double-tap shortcut on or off (off whenever the push-to-talk chord is that key alone).
    public func setDoubleTapEnabled(_ enabled: Bool) {
        doubleTapEnabled.withLock { $0 = enabled }
    }

    /// Which key is tapped twice (Control by default).
    public func setDoubleTapKey(_ key: ModifierSet) {
        doubleTapKey.withLock { $0 = key }
        perform { monitor in
            guard monitor.doubleTap.key != key else { return }
            monitor.doubleTap = DoubleTapDetector(key: key)
        }
    }

    /// Ends a turn in progress from outside (e.g. Escape pressed in the overlay).
    public func cancelCurrent() {
        perform { monitor in
            if let event = monitor.machine.handle(.interrupted(at: ProcessInfo.processInfo.systemUptime)) {
                monitor.emit(event)
            }
        }
    }

    /// True when a listen-only tap can be created right now (a live check of Input Monitoring).
    public static func canCreateTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let probe = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .listenOnly, eventsOfInterest: mask,
                                            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                            userInfo: nil) else { return false }
        CFMachPortInvalidate(probe)
        return true
    }

    /// Whether a password field (or another app) has enabled Secure Event Input, which hides keys from taps.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    // MARK: - Tap thread

    private func perform(_ block: @escaping (HotkeyMonitor) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if let self { block(self) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func threadMain() {
        machine.chord = desiredChord.withLock { $0 }
        machine.reset()
        doubleTap = DoubleTapDetector(key: doubleTapKey.withLock { $0 })
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon)
        startLock.lock()
        guard let tap else {
            startResult = false
            startLock.signal()
            startLock.unlock()
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        let runLoop = CFRunLoopGetCurrent()
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // A once-a-second tick enforces the maximum hold even if no key events arrive.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 0.5, 0, 0) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let event = self.machine.tick(now: now) { self.emit(event); return }
            // A release can be missed (secure input, lock screen, tap disabled). Only then, while listening, resync
            // with the keyboard state so the microphone never stays on after the keys are up. Not otherwise:
            // `flagsState` doesn't report Fn, so resyncing on every tick ended Fn chords after ~0.5 s (2026-10-01).
            if self.machine.isListening, self.eventsMayBeMissing || IsSecureEventInputEnabled() {
                let mods = Self.resyncedModifiers(last: self.lastModifiers)
                if mods != self.lastModifiers {
                    self.lastModifiers = mods
                    self.emitModifiers(mods)
                    if let event = self.machine.handle(.modifiersChanged(mods, at: now)) { self.emit(event) }
                }
            }
        }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        tickTimer = timer

        startResult = true
        startLock.signal()
        startLock.unlock()
        CFRunLoopRun()
    }

    /// Current modifiers from the system's key state. Fn isn't reported there, so it keeps its last known state
    /// (a missed Fn release is still caught by the other chord keys or the maximum hold).
    static func resyncedModifiers(last: ModifierSet) -> ModifierSet {
        var mods = modifiers(from: CGEventSource.flagsState(.combinedSessionState))
        if last.contains(.function) { mods.insert(.function) }
        return mods
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .flagsChanged:
            eventsMayBeMissing = false
            let mods = Self.modifiers(from: event.flags)
            guard mods != lastModifiers else { return }
            lastModifiers = mods
            emitModifiers(mods)
            if doubleTap.modifiersChanged(mods, at: now), doubleTapEnabled.withLock({ $0 }), !machine.isListening {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onDoubleTap?() } }
            }
            if let chordEvent = machine.handle(.modifiersChanged(mods, at: now)) { emit(chordEvent) }
        case .keyDown:
            eventsMayBeMissing = false
            doubleTap.keyPressed()
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape), lastModifiers.isEmpty,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onEscape?() } }
            }
            // Auto-repeat of a key held before the chord also counts: the chord is part of a shortcut.
            if let chordEvent = machine.handle(.keyDown(at: now)) { emit(chordEvent) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables taps that are slow or during secure input; turn it back on and resync,
            // because key-up events may have been missed while it was off.
            Log.hotkey.notice("event tap was disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            eventsMayBeMissing = true
            let mods = Self.resyncedModifiers(last: lastModifiers)
            lastModifiers = mods
            emitModifiers(mods)
            if let chordEvent = machine.handle(.modifiersChanged(mods, at: now)) { emit(chordEvent) }
        default:
            break
        }
    }

    private func emit(_ event: ChordEvent) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }

    private func emitModifiers(_ mods: ModifierSet) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onModifiersChanged?(mods) }
        }
    }

    static func modifiers(from flags: CGEventFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { set.insert(.function) }
        return set
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    // Listen-only: always pass the event through untouched.
    return Unmanaged.passUnretained(event)
}
