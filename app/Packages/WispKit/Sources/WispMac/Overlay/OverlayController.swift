import AppKit
import QuartzCore
import WispCore

/// What the companion is doing for the current turn.
public enum CompanionMode: Equatable, Sendable {
    /// No turn in progress (the companion is home in the menu bar, or idling beside the pointer).
    case hidden
    /// Listening while the chord is held; shows a live level meter.
    case listening
    /// Waiting for the answer.
    case thinking
    /// Speaking or showing the answer.
    case resting
}

/// Draws Wisp's companion cursor. One transparent, click-through panel per display, each with its own display
/// link (so every display renders at its own refresh rate); the shared state advances once per frame.
///
/// Placement: by default the companion lives in the menu bar icon, flies out to the pointer when a turn
/// starts and flies home when it ends. With "keep on screen" it stays beside the pointer all the time.
@MainActor
public final class OverlayController: NSObject {
    // MARK: Configuration

    public var theme: CompanionTheme = ThemeCatalog.theme(id: ThemeCatalog.defaultID)
    /// Companion size multiplier (`OverlaySettings.scaleRange`).
    public var companionScale: Double = 1.0 {
        didSet { if companionScale != oldValue { windows.forEach { $0.overlayView.canvasScale = companionScale } } }
    }
    /// Opacity while idle beside the pointer in keep-on-screen mode.
    public var idleOpacity: Double = 0.85
    public var outline: CompanionOutline = .white
    public var keepOnScreen = false {
        didSet {
            guard keepOnScreen != oldValue else { return }
            if keepOnScreen && (placement == .docked || isFlyingHome) { flyOut() }
            if !keepOnScreen && mode == .hidden && placement != .docked && !isFlyingHome { flyHome() }
        }
    }
    /// The user's Reduce Motion preference; `.system` follows System Settings live.
    public var reduceMotionPreference: ReduceMotionPreference = .system { didSet { updateReduceMotion() } }
    public private(set) var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Where the companion lives when docked (centre of the menu bar icon, global coordinates).
    public var menuBarAnchor: (() -> Vec2?)?
    /// Called when the companion leaves / returns to the menu bar icon (for the icon's own animation).
    public var onLeftHome: (() -> Void)?
    public var onArrivedHome: (() -> Void)?

    /// Offset from the system pointer's hotspot to the companion's tip, so it sits beside the real cursor.
    public var followOffset = Vec2(22, -18)
    /// Base canvas size (points) at scale 1; the arrow is ~62 % of it (≈ 35 pt, a large custom cursor).
    nonisolated static let baseCanvas: CGFloat = 56

    // MARK: State

    private enum Placement: Equatable { case docked, flying, following, performing }

    /// One gesture being performed: fly to its start, then act (point or trace), then hold there.
    private struct Performance {
        enum Phase { case approach, act, hold }
        var gesture: Gesture
        var phase: Phase
        var phaseStart: CFTimeInterval
        var from: Vec2
        var approach: Double
        var inkIndex: Int?
        /// Runs the moment a point "clicks" (the ring pops), for actions that must happen exactly then.
        var onPress: ((Bool) -> Void)?
    }

    /// Ink left by a traced gesture.
    struct Ink {
        var path: TracePath
        var progress: Double
    }

    /// A highlight ring around a pointed-at spot.
    struct Ring {
        var center: Vec2
        var born: CFTimeInterval
        var label: String
    }
    private struct Flight {
        enum Kind { case out, home }
        var kind: Kind
        var start: Vec2
        var startTime: CFTimeInterval
        var duration: Double
        // Values at the start of the flight, so a flight that interrupts another blends instead of popping.
        var startScale: Double
        var startOpacity: Double
        var startTilt: Double
    }

    private var windows: [OverlayWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var linksRunning = false
    private var lastAdvance: CFTimeInterval = 0
    public private(set) var mode: CompanionMode = .hidden
    private var placement: Placement = .docked
    private var flight: Flight?
    private var spring = Spring2D(position: .zero, response: 0.16, dampingRatio: 0.92)
    private var position = Vec2.zero
    private var lastTarget = Vec2.zero
    private var stillSince: CFTimeInterval = 0
    private var level: Float = 0
    private var opacity: Double = 0
    private var flightScale: Double = 1
    private var tilt: Double = 0
    private var glow: Double = 0
    private var morph: Double = 0
    private var squash: Double = 0
    private var gestureQueue: [Gesture] = []
    /// Click handlers for queued gestures (same order as `gestureQueue`).
    private var pressQueue: [((Bool) -> Void)?] = []
    /// Per queued gesture: move at a deliberate, human pace (computer-use steps) instead of a quick swoop.
    private var slowQueue: [Bool] = []
    private var performance: Performance?
    private var inks: [Ink] = []
    private var rings: [Ring] = []
    /// 1 = drawings fully visible; fades to 0 when the answer is over.
    private var drawingAlpha: Double = 1
    private var endRequestedAt: CFTimeInterval?
    private var currentFrame = CompanionFrame.hidden(at: .zero, theme: ThemeCatalog.theme(id: ThemeCatalog.defaultID))
    private let epoch = CACurrentMediaTime()

    public override init() {
        super.init()
        rebuildWindows()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReduceMotion() }
        }
    }

    /// Window numbers of every overlay panel.
    public var windowNumbers: [Int] { windows.map(\.windowNumber) }

    private var isFlyingHome: Bool { placement == .flying && flight?.kind == .home }

    // MARK: Turn API

    public func setMode(_ newMode: CompanionMode) {
        guard newMode != mode else { return }
        let previous = mode
        mode = newMode
        if newMode != .listening { level = 0 }
        switch newMode {
        case .listening, .thinking, .resting:
            // Also re-launch if it is on its way home (a new turn started during the fly-home).
            if placement == .docked || isFlyingHome { flyOut() }
            if newMode == .listening { squash = 1 } // tiny "press" squash as listening starts
        case .hidden:
            if placement == .performing || !inks.isEmpty || !rings.isEmpty {
                // Let the last gesture finish and the drawings be seen, then fade and go home (see advance()).
                endRequestedAt = CACurrentMediaTime()
            } else if !keepOnScreen && previous != .hidden && placement != .docked && !isFlyingHome {
                flyHome()
            }
        }
        startLinks()
    }

    /// Queues a gesture (point at something, or trace a shape). Performed in order, each after the previous one's
    /// action finishes.
    public func perform(_ gesture: Gesture) {
        switch gesture {
        case .point: Log.overlay.info("gesture: point")
        case .trace(let path, _): Log.overlay.info("gesture: trace \(path.kind.rawValue, privacy: .public)")
        }
        endRequestedAt = nil
        drawingAlpha = 1
        gestureQueue.append(gesture)
        pressQueue.append(nil)
        slowQueue.append(false)
        if performance == nil || performance?.phase == .hold { startNextGesture(now: CACurrentMediaTime()) }
        startLinks()
    }

    /// Removes all drawings immediately (new question, Escape).
    public func clearDrawings() {
        gestureQueue.removeAll()
        // Anyone waiting for a click that will never come is let go.
        let waiting = pressQueue.compactMap { $0 } + [performance?.onPress].compactMap { $0 }
        pressQueue.removeAll()
        slowQueue.removeAll()
        performance?.onPress = nil
        waiting.forEach { $0(false) }
        performance = nil
        inks.removeAll()
        rings.removeAll()
        drawingAlpha = 1
        endRequestedAt = nil
        morph = 0
        if placement == .performing { placement = .following; spring.snap(to: position) }
    }

    /// Points at `at` and returns the moment the cursor "clicks" there (true), or false if it was cancelled first.
    /// For actions that should happen exactly as the cursor clicks.
    public func pointAndClick(at: Vec2, label: String = "", deliberate: Bool = true) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            endRequestedAt = nil
            drawingAlpha = 1
            gestureQueue.append(.point(at: at, label: label))
            slowQueue.append(deliberate)
            pressQueue.append { clicked in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: clicked)
            }
            if performance == nil || performance?.phase == .hold { startNextGesture(now: CACurrentMediaTime()) }
            startLinks()
        }
    }

    /// Changes the label next to the newest point (the browser action "types" into it letter by letter).
    public func updatePointLabel(_ text: String) {
        guard !rings.isEmpty else { return }
        rings[rings.count - 1].label = text
        startLinks()
    }

    /// Something is drawn or about to be (a point, ring or trace still on screen).
    public var hasDrawings: Bool { !inks.isEmpty || !rings.isEmpty || performance != nil || !gestureQueue.isEmpty }

    /// Screen area the companion is currently highlighting (for keeping captions off it).
    public var highlightRect: CGRect? {
        if let ink = inks.last {
            let xs = ink.path.points.map(\.x), ys = ink.path.points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        if let ring = rings.last { return CGRect(x: ring.center.x - 40, y: ring.center.y - 40, width: 80, height: 80) }
        return nil
    }

    private func startNextGesture(now: CFTimeInterval) {
        guard !gestureQueue.isEmpty else { return }
        let gesture = gestureQueue.removeFirst()
        let onPress = pressQueue.isEmpty ? nil : pressQueue.removeFirst()
        let slow = slowQueue.isEmpty ? false : slowQueue.removeFirst()
        if placement == .docked { flyOut(); spring.snap(to: position) }
        let target: Vec2
        switch gesture {
        case .point(let p, _): target = p
        case .trace(let path, _): target = path.start
        }
        let distance = position.distance(to: target)
        let approach = reduceMotion ? 0 : slow ? min(1.25, max(0.55, 0.38 + distance / 1500)) : min(0.6, max(0.22, 0.16 + distance / 3000))
        flight = nil
        placement = .performing
        performance = Performance(gesture: gesture, phase: .approach, phaseStart: now, from: position,
                                  approach: approach, inkIndex: nil, onPress: onPress)
    }

    /// Live microphone level, 0...1.
    public func setLevel(_ value: Float) { level = value }

    /// Applies overlay settings (theme, size, idle opacity, outline, keep-on-screen, reduce-motion preference).
    public func apply(_ settings: OverlaySettings) {
        let s = settings.sanitized
        theme = s.resolvedTheme
        companionScale = s.cursorScale
        idleOpacity = s.idleOpacity
        outline = s.outline
        reduceMotionPreference = s.reduceMotion
        keepOnScreen = s.keepOnScreen
        startLinks()
    }

    private func updateReduceMotion() {
        switch reduceMotionPreference {
        case .system: reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        case .on: reduceMotion = true
        case .off: reduceMotion = false
        }
    }

    // MARK: Flights

    private func homePoint() -> Vec2 {
        if let anchor = menuBarAnchor?() { return anchor }
        // No status item visible (hidden by the notch or removed): emerge from the top of the pointer's screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        return Vec2(mouse.x, frame.maxY - 4)
    }

    private func flyOut() {
        let fromHome = placement == .docked
        let start = fromHome ? homePoint() : position
        if fromHome {
            position = start
            flightScale = 0.32
            opacity = 0
            tilt = 0
            onLeftHome?()
        }
        spring.snap(to: start)
        placement = .flying
        let distance = start.distance(to: pointerTarget())
        flight = Flight(kind: .out, start: start, startTime: CACurrentMediaTime(),
                        duration: reduceMotion ? 0.16 : FlightPath.duration(forDistance: distance),
                        startScale: flightScale, startOpacity: opacity, startTilt: tilt)
        startLinks()
    }

    private func flyHome() {
        placement = .flying
        let start = position
        let distance = start.distance(to: homePoint())
        flight = Flight(kind: .home, start: start, startTime: CACurrentMediaTime(),
                        duration: reduceMotion ? 0.14 : FlightPath.duration(forDistance: distance, minimum: 0.32, maximum: 0.7),
                        startScale: flightScale, startOpacity: opacity, startTilt: tilt)
        startLinks()
    }

    // MARK: Windows and display links

    private func rebuildWindows() {
        stopLinks()
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.overlayView.canvasScale = companionScale
            window.overlayView.onFrame = { [weak self, weak window] timestamp in
                guard let self, let view = window?.overlayView else { return }
                self.advance(to: timestamp)
                view.render(self.currentFrame)
            }
            return window
        }
        windows.forEach { $0.orderFrontRegardless() }
        startLinks()
        Log.overlay.info("overlay windows: \(self.windows.count, privacy: .public)")
    }

    private func startLinks() {
        guard !linksRunning else { return }
        linksRunning = true
        lastAdvance = 0
        windows.forEach { $0.overlayView.startDisplayLink() }
    }

    private func stopLinks() {
        linksRunning = false
        windows.forEach { $0.overlayView.stopDisplayLink() }
    }

    private func pointerTarget() -> Vec2 {
        let k = companionScale
        let offset = Vec2(followOffset.x * k, followOffset.y * k)
        if let demo = Self.demoTarget { return demo + offset }
        let mouse = NSEvent.mouseLocation
        return Vec2(mouse.x, mouse.y) + offset
    }

    /// Debug builds: `WISP_DEMO_TARGET=x,y` pins the companion's target to a fixed global point so overlay
    /// animations can be tested and captured without moving the user's real pointer.
    private static let demoTarget: Vec2? = {
        #if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["WISP_DEMO_TARGET"] else { return nil }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? Vec2(parts[0], parts[1]) : nil
        #else
        return nil
        #endif
    }()

    // MARK: Per-frame update

    /// Advances the shared state once per frame, no matter how many displays ask (each link calls this).
    private func advance(to timestamp: CFTimeInterval) {
        guard timestamp > lastAdvance + 0.002 else { return }
        let dt = lastAdvance == 0 ? 1.0 / 60.0 : min(1.0 / 20.0, timestamp - lastAdvance)
        lastAdvance = timestamp
        let target = pointerTarget()
        if target.distance(to: lastTarget) > 0.4 { stillSince = timestamp }
        lastTarget = target

        var targetOpacity: Double
        switch placement {
        case .docked:
            targetOpacity = 0
        case .following:
            if reduceMotion { spring.snap(to: target) } else { spring.step(dt: dt, target: target) }
            position = spring.position
            flightScale += (1 - flightScale) * min(1, dt * 12)
            tilt += (0 - tilt) * min(1, dt * 12)
            targetOpacity = mode == .hidden ? idleOpacity : 1
        case .flying:
            targetOpacity = 1
            advanceFlight(now: timestamp, target: target)
        case .performing:
            targetOpacity = 1
            advancePerformance(now: timestamp, dt: dt)
        }
        if let ended = endRequestedAt, performance?.phase != .act, performance?.phase != .approach, gestureQueue.isEmpty {
            // Hold the drawings briefly after the answer, fade them, then return home (or to the pointer).
            let since = timestamp - ended
            if since > 1.2 { drawingAlpha = max(0, drawingAlpha - dt / 0.5) }
            if since > 1.2 && placement == .performing {
                performance = nil
                morph = 0
                if keepOnScreen {
                    placement = .following
                    spring.snap(to: position)
                } else {
                    flyHome()
                }
            }
            if drawingAlpha <= 0 {
                inks.removeAll()
                rings.removeAll()
                endRequestedAt = nil
                drawingAlpha = 1
            }
        }
        if placement != .flying {
            opacity += (targetOpacity - opacity) * min(1, dt * 12)
        }

        // Emphasis: glow follows the voice while listening, breathes while thinking.
        let glowTarget: Double
        switch mode {
        case .listening: glowTarget = 0.35 + 0.65 * Double(level)
        case .thinking: glowTarget = reduceMotion ? 0.4 : 0.3 + 0.25 * (0.5 + 0.5 * sin(timestamp * 3.2))
        case .resting: glowTarget = 0.2
        case .hidden: glowTarget = 0
        }
        glow += (glowTarget - glow) * min(1, dt * 10)
        squash = max(0, squash - dt * 6)

        // Pattern time since launch, wrapped daily (float precision); a once-a-day jump is invisible in practice.
        let patternTime = (timestamp - epoch).truncatingRemainder(dividingBy: 86_400)
        currentFrame = CompanionFrame(position: position, opacity: opacity, mode: mode, level: level, time: patternTime,
                                      scale: flightScale, tilt: tilt, glow: glow, morph: morph, squash: squash,
                                      theme: theme, outline: outline, reduceMotion: reduceMotion,
                                      inks: inks.map { $0.path.prefix($0.progress) }, rings: rings.map { ring in
                                          // Pops in 1.6x → 1x, then breathes gently.
                                          let age = timestamp - ring.born
                                          let pop = age < 0.35 && !reduceMotion ? 1 + 0.6 * (1 - Easing.outBack(age / 0.35, overshoot: 0.6)) : 1
                                          let breathe = reduceMotion ? 1 : 1 + 0.05 * sin(age * 3)
                                          let labelAge = age - 0.15
                                          let labelPop = labelAge <= 0 ? 0 : (reduceMotion ? 1 : min(1.0, Easing.outBack(labelAge / 0.3, overshoot: 1.2)))
                                          return RingFrame(center: ring.center, radius: 22 * pop * breathe, alpha: min(1, age / 0.12),
                                                           label: ring.label, labelScale: labelPop)
                                      }, drawingAlpha: drawingAlpha)

        // Idle beside a still pointer: 20 fps is plenty for the slow fluid drift (saves battery).
        // Pointer movement, flights and turns run at each display's full rate.
        let idle = placement == .following && mode == .hidden && timestamp - stillSince > 0.25
        windows.forEach { $0.overlayView.setIdleFrameRate(idle) }

        // Sleep every display link once nothing is visible.
        if placement == .docked && opacity < 0.005 && inks.isEmpty && rings.isEmpty {
            currentFrame = CompanionFrame.hidden(at: position, theme: theme)
            windows.forEach { $0.overlayView.render(currentFrame) }
            stopLinks()
        }
    }

    private func advanceFlight(now: CFTimeInterval, target: Vec2) {
        guard let flight else { placement = .following; return }
        let raw = min(1, (now - flight.startTime) / max(flight.duration, 0.01))
        switch flight.kind {
        case .out:
            if reduceMotion {
                position = target
                opacity = flight.startOpacity + (1 - flight.startOpacity) * raw
                flightScale = 1
                tilt = 0
            } else {
                let path = FlightPath(start: flight.start, end: target, arc: 0.16)
                let e = Easing.outBack(raw, overshoot: 0.55)
                position = path.point(at: min(e, 1.04))
                let grow = Easing.outBack(raw, overshoot: 1.1)
                flightScale = flight.startScale + (1 - flight.startScale) * grow
                opacity = flight.startOpacity + (1 - flight.startOpacity) * min(1, raw / 0.22)
                let lead = Self.leadTilt(direction: path.direction(at: min(raw, 0.98))) * sin(Double.pi * raw) * 0.75
                tilt = flight.startTilt * (1 - raw) + lead
            }
            if raw >= 1 {
                self.flight = nil
                placement = .following
                spring.snap(to: position)
                squash = 0.8
            }
        case .home:
            let home = homePoint()
            if reduceMotion {
                opacity = flight.startOpacity * (1 - raw)
            } else {
                let path = FlightPath(start: flight.start, end: home, arc: -0.14)
                position = path.point(at: Easing.inOutCubic(raw))
                let shrink = Easing.inCubic(raw)
                flightScale = flight.startScale + (0.3 - flight.startScale) * shrink
                let fade = raw < 0.7 ? 1 : max(0, 1 - (raw - 0.7) / 0.3)
                opacity = flight.startOpacity * fade
                let lead = Self.leadTilt(direction: path.direction(at: min(raw, 0.98))) * sin(Double.pi * raw) * 0.75
                tilt = flight.startTilt * (1 - raw) + lead
            }
            if raw >= 1 {
                self.flight = nil
                placement = .docked
                opacity = 0
                position = home
                onArrivedHome?()
                // A new turn (or keep-on-screen) arrived while flying home: head straight back out.
                if mode != .hidden || keepOnScreen { flyOut() }
            }
        }
    }

    private func advancePerformance(now: CFTimeInterval, dt: Double) {
        guard var p = performance else { placement = .following; return }
        let elapsed = now - p.phaseStart
        switch p.phase {
        case .approach:
            let target: Vec2
            switch p.gesture {
            case .point(let at, _): target = at
            case .trace(let path, _): target = path.start
            }
            let raw = p.approach > 0 ? min(1, elapsed / p.approach) : 1
            let path = FlightPath(start: p.from, end: target, arc: 0.12)
            position = path.point(at: Easing.inOutCubic(raw))
            tilt = Self.leadTilt(direction: path.direction(at: min(raw, 0.98))) * sin(Double.pi * raw) * 0.6
            // Swoop: grow a little mid-flight and settle back on landing (longer flights swoop more).
            let swoop = reduceMotion ? 0 : min(0.3, path.distance / 2400) * sin(Double.pi * raw)
            flightScale = 1 + swoop
            morph += (0 - morph) * min(1, dt * 14)
            if raw >= 1 {
                p.phase = .act
                p.phaseStart = now
                tilt = 0
                switch p.gesture {
                case .point(let at, let label):
                    rings.append(Ring(center: at, born: now, label: label))
                    squash = 0.8
                    // The click: whatever was waiting for it happens now, in step with the ring.
                    if let press = p.onPress { p.onPress = nil; press(true) }
                case .trace(let tracePath, _):
                    inks.append(Ink(path: tracePath, progress: reduceMotion ? 1 : 0))
                    p.inkIndex = inks.count - 1
                }
            }
        case .act:
            switch p.gesture {
            case .point:
                // The arrow tip lands on the target with a small "press" (the ring pops around it).
                if elapsed > 0.35 { p.phase = .hold; p.phaseStart = now }
            case .trace(let tracePath, _):
                let raw = reduceMotion ? 1 : min(1, elapsed / tracePath.duration)
                // Pen speed eases in and out, like a hand starting and finishing a stroke.
                let f = Easing.inOutCubic(raw)
                position = tracePath.point(atFraction: f)
                if let i = p.inkIndex, i < inks.count { inks[i].progress = f }
                // Lean slightly into the stroke direction while drawing.
                let d = tracePath.direction(atFraction: f)
                tilt += (max(-0.25, min(0.25, d.x * 0.2)) - tilt) * min(1, dt * 10)
                if raw >= 1 { p.phase = .hold; p.phaseStart = now; tilt = 0 }
            }
        case .hold:
            tilt += (0 - tilt) * min(1, dt * 10)
            if !gestureQueue.isEmpty && elapsed > 0.25 {
                performance = p
                startNextGesture(now: now)
                return
            }
        }
        performance = p
    }

    /// Rotation (radians, counter-clockwise) that points the arrow's tip along `direction`. The arrow's
    /// resting "forward" is up and slightly left; we rotate only part of the way so it stays recognisable.
    static func leadTilt(direction d: Vec2) -> Double {
        let forward = atan2(1.0, -0.42)          // resting tip direction (y up)
        let travel = atan2(d.y, d.x)
        var delta = travel - forward
        while delta > Double.pi { delta -= 2 * Double.pi }
        while delta < -Double.pi { delta += 2 * Double.pi }
        return max(-0.9, min(0.9, delta))
    }
}

/// Everything a display needs to draw one frame.
struct CompanionFrame {
    var position: Vec2
    var opacity: Double
    var mode: CompanionMode
    var level: Float
    var time: CFTimeInterval
    /// Flight scale (multiplies the configured companion size).
    var scale: Double
    var tilt: Double
    var glow: Double
    var morph: Double
    var squash: Double
    var theme: CompanionTheme
    var outline: CompanionOutline
    var reduceMotion: Bool
    var inks: [[Vec2]] = []
    var rings: [RingFrame] = []
    var drawingAlpha: Double = 1

    static func hidden(at p: Vec2, theme: CompanionTheme) -> CompanionFrame {
        CompanionFrame(position: p, opacity: 0, mode: .hidden, level: 0, time: 0, scale: 1, tilt: 0, glow: 0,
                       morph: 0, squash: 0, theme: theme, outline: .none, reduceMotion: false)
    }
}

struct RingFrame {
    var center: Vec2
    var radius: Double
    var alpha: Double
    var label: String = ""
    /// 0 = hidden, 1 = full size (pops in shortly after the ring).
    var labelScale: Double = 0
}

/// A borderless, transparent, click-through panel covering one display, above almost everything.
final class OverlayWindow: NSPanel {
    let overlayView: OverlayView

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Above the menu bar (the companion flies out of its icon) and full-screen apps, below the cursor.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
        setFrame(screen.frame, display: false)
        // Purely decorative and click-through: keep it out of the accessibility tree.
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
