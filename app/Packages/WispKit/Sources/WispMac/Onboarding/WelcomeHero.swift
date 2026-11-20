import AppKit
import ApplicationServices
import CoreImage
import QuartzCore
import SwiftUI

// Welcome hero, v2 — "the orb kicks the squircle into the Trash".
//
// The app icon on the "Meet Wisp" page comes alive:
//   1. The icon at rest: dark squircle, iridescent glass orb, the orb's coloured glow on the squircle.
//   2. The orb jiggles, crouches and pops out of the squircle, taking its light with it: a soft, colourful shadow
//      separates from it and stretches as it lifts. It drops back for one small bounce in its socket…
//   3. …glides up and away at 45° (counter-clockwise from straight up, i.e. away from the Trash),
//   4. drops onto the top of the now-empty squircle and bounces there. The Dock shows up (the real one; if it's
//      hidden or can't be found, a Dock is drawn sliding up from the bottom of the screen).
//   5. The orb hops off the side, winds up and rams the squircle, which tumbles in an arc into the Trash; the Trash
//      gulps it (and shows as full).
//   6. The orb floats back to where the icon was and takes its place: hovering, bobbing gently, a colourful shadow
//      breathing underneath, its film shimmering. "Hi, I'm Wisp" rises in slowly underneath (a caption, no audio).
// Clicking replays it. Reduce Motion: a cross-fade straight to the final hovering state (still) plus the caption.
//
// Structure
//   WelcomeHero              SwiftUI wrapper (same surface as v1: `WelcomeHero(onHello:)`).
//   WelcomeHeroView          The icon/orb layers in the window, the caption, the idle hover, replay.
//   HeroChoreography         Pure, deterministic timeline: `sample(t)` -> HeroFrame. No AppKit state.
//   HeroRunner               Plays a choreography with a display link in a transparent full-screen panel.
//   TrashLocator / FakeDock  Finds the Dock's Trash, or lays out a drawn Dock when it can't.
//   WelcomeHeroAssets        The one place that loads the PNGs (swap the body for Bundle.module).

// MARK: - SwiftUI surface

struct WelcomeHero: NSViewRepresentable {
    var onHello: () -> Void
    /// Called when a (re)play starts. Optional.
    var onStart: (() -> Void)? = nil

    func makeNSView(context: Context) -> WelcomeHeroView {
        let view = WelcomeHeroView()
        view.onHello = onHello
        view.onStart = onStart
        return view
    }

    func updateNSView(_ nsView: WelcomeHeroView, context: Context) {
        nsView.onHello = onHello
        nsView.onStart = onStart
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WelcomeHeroView, context: Context) -> CGSize? {
        CGSize(width: WelcomeHeroView.side, height: WelcomeHeroView.side)
    }
}

// MARK: - Assets

@MainActor
enum WelcomeHeroAssets {
    /// Where the PNGs live when not using a bundle (the test harness sets this).
    static var directory: URL?

    /// The single loading hook: the package's Welcome folder (or `directory`, for the test harness).
    static func url(for name: String) -> URL? {
        if let directory { return directory.appendingPathComponent(name + ".png") }
        return Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Welcome")
    }

    static func load(_ name: String) -> CGImage? {
        guard let url = url(for: name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// High-quality downsample to the exact pixel size it's shown at, so the resting icon is crisp and the hand-offs
    /// between the window and the flight panel are pixel-identical.
    static func resample(_ image: CGImage?, pixels: Int) -> CGImage? {
        guard let image, pixels > 0, let ctx = context(pixels, pixels) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return ctx.makeImage()
    }

    /// The orb's coloured light: the bubble's own colours, blurred into a soft disc and saturated. `side` px square;
    /// the disc's nominal diameter is half the side (the rest is falloff).
    static func colourDisc(from bubbleCanvas: CGImage?, side: Int) -> CGImage? {
        guard let bubbleCanvas, side > 0, let ctx = context(side, side) else { return nil }
        // Crop the bubble out of its 1024 canvas and draw it at half the side, centred.
        let k = CGFloat(bubbleCanvas.width) / 1024
        let c = WelcomeHeroView.canvasBubbleCenter, r = WelcomeHeroView.canvasBubbleRadius
        guard let orb = bubbleCanvas.cropping(to: CGRect(x: (c.x - r) * k, y: (c.y - r) * k, width: 2 * r * k, height: 2 * r * k))
        else { return nil }
        let d = CGFloat(side) / 2
        ctx.interpolationQuality = .high
        ctx.draw(orb, in: CGRect(x: d / 2, y: d / 2, width: d, height: d))
        guard let sharp = ctx.makeImage() else { return nil }
        var ci = CIImage(cgImage: sharp)
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7, kCIInputBrightnessKey: 0.04])
        ci = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(d) * 0.16).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        // Soften the edge to zero so the layer's square never shows.
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: CGFloat(side) / 2, y: CGFloat(side) / 2),
            "inputRadius0": d * 0.55, "inputRadius1": d * 0.98,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0)])?.outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        if let mask { ci = ci.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask]) }
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(ci, from: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// The system Trash icon (empty or full) rendered at `pixels`.
    static func trashIcon(full: Bool, pixels: Int) -> CGImage? {
        guard let image = NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

// MARK: - The view

final class WelcomeHeroView: NSView {
    static let side: CGFloat = 104

    /// Test hooks (the harness sets these; the app never needs to).
    struct Testing {
        var forceNoTrash = false
        var forceReduceMotion = false
        var skipAccessibility = false
        var autoPlayDelay: Double = 1.0
        var onTick: ((Double) -> Void)?
        var onSlowFrame: ((Double, Double) -> Void)?   // (t, ms of main-thread work)
    }
    @MainActor static var testing = Testing()

    var onHello: (() -> Void)?
    var onStart: (() -> Void)?
    /// Draw the "Hi, I'm Wisp" caption under the orb. Turn off if the page shows its own.
    var showsCaption = true
    static let captionText = "Hi, I\u{2019}m Wisp"

    private let tileLayer = CALayer()      // squircle + glow + bloom; reacts as a unit
    private let baseLayer = CALayer()
    private let glowLayer = CALayer()
    private let bloomLayer = CALayer()     // a second additive copy of the glow, for flashes
    private let shadowLayer = CALayer()    // the orb's colourful shadow (final state)
    private let haloLayer = CALayer()      // the orb's glow (final state)
    private let bubbleLayer = CALayer()    // the orb (full icon canvas, anchored at the orb's centre)
    private let caption = NSTextField(labelWithString: WelcomeHeroView.captionText)
    private var sources: (base: CGImage?, glow: CGImage?, bubble: CGImage?) = (nil, nil, nil)
    private var renderedScale: CGFloat = 0
    private(set) var bubbleImage: CGImage?
    private(set) var squircleImage: CGImage?
    private(set) var discImage: CGImage?
    private var runner: HeroRunner?
    private var played = false
    private var isFinal = false
    private var resetting = false
    private var autoPlayTask: Task<Void, Never>?

    /// Bubble centre and radius in the 1024-pt icon canvas (top-left origin), from tools/make_app_icon.py.
    static let canvasBubbleCenter = CGPoint(x: 512, y: 504)
    static let canvasBubbleRadius: CGFloat = 288
    /// Half the side of the squircle's body in the canvas (without its drop shadow).
    static let canvasBodyHalf: CGFloat = 412

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Wisp")
        sources = (WelcomeHeroAssets.load("squircle-empty"), WelcomeHeroAssets.load("glow"), WelcomeHeroAssets.load("bubble"))
        glowLayer.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        bloomLayer.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        bloomLayer.opacity = 0
        for l in [baseLayer, glowLayer, bloomLayer] { tileLayer.addSublayer(l) }
        for l in [tileLayer, haloLayer, shadowLayer, bubbleLayer] { layer?.addSublayer(l) }
        for l in [tileLayer, baseLayer, glowLayer, bloomLayer, bubbleLayer, shadowLayer, haloLayer] {
            l.contentsGravity = .resize
            l.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                         "opacity": NSNull(), "hidden": NSNull(), "filters": NSNull()]
        }
        shadowLayer.opacity = 0
        haloLayer.opacity = 0
        bubbleLayer.anchorPoint = Self.bubbleAnchor
        bubbleLayer.filters = [Self.hueFilter()]
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.86)
        caption.alignment = .center
        caption.alphaValue = 0
        caption.wantsLayer = true
        caption.setAccessibilityElement(false)
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func hueFilter() -> CIFilter {
        let f = CIFilter(name: "CIHueAdjust")!
        f.setValue(0, forKey: kCIInputAngleKey)
        f.name = "hue"
        return f
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override var isFlipped: Bool { false }

    /// Anchor point of the orb inside the canvas (unit coordinates, y up).
    static var bubbleAnchor: CGPoint {
        CGPoint(x: canvasBubbleCenter.x / 1024, y: 1 - canvasBubbleCenter.y / 1024)
    }
    var bubbleCenterInView: CGPoint {
        CGPoint(x: bounds.width * Self.bubbleAnchor.x, y: bounds.height * Self.bubbleAnchor.y)
    }
    var bubbleRadius: CGFloat { Self.canvasBubbleRadius * bounds.width / 1024 }
    var bodyHalf: CGFloat { Self.canvasBodyHalf * bounds.width / 1024 }
    /// Where the orb hovers in the final state (view coordinates).
    var hoverCenterInView: CGPoint { bubbleCenterInView.applying(.init(translationX: 0, y: HeroChoreography.hoverLift)) }

    override func layout() {
        super.layout()
        refreshImagesIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileLayer.bounds = bounds
        tileLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for l in [baseLayer, glowLayer, bloomLayer] { l.frame = tileLayer.bounds }
        bubbleLayer.bounds = bounds
        let disc = HeroChoreography.discSide(radius: bubbleRadius)
        for l in [shadowLayer, haloLayer] { l.bounds = CGRect(x: 0, y: 0, width: disc, height: disc) }
        if !isFinal { bubbleLayer.position = bubbleCenterInView }
        caption.frame = CGRect(x: -20, y: 0, width: bounds.width + 40, height: 18)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func refreshImagesIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        guard scale != renderedScale, bounds.width > 0 else { return }
        renderedScale = scale
        let px = Int((bounds.width * scale).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        squircleImage = WelcomeHeroAssets.resample(sources.base, pixels: px)
        baseLayer.contents = squircleImage
        let glow = WelcomeHeroAssets.resample(sources.glow, pixels: px)
        glowLayer.contents = glow
        bloomLayer.contents = glow
        bubbleImage = WelcomeHeroAssets.resample(sources.bubble, pixels: px)
        bubbleLayer.contents = bubbleImage
        discImage = WelcomeHeroAssets.colourDisc(from: sources.bubble,
                                                 side: Int((HeroChoreography.discSide(radius: bubbleRadius) * scale).rounded()))
        shadowLayer.contents = discImage
        haloLayer.contents = discImage
        for l in [baseLayer, glowLayer, bloomLayer, bubbleLayer, shadowLayer, haloLayer] { l.contentsScale = scale }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            autoPlayTask?.cancel()
            runner?.cancel()
            return
        }
        guard !played else { return }
        played = true
        let delay = Self.testing.autoPlayDelay
        // Let the welcome screen settle (and its slide-in finish) before the show starts.
        autoPlayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.playWhenVisible()
        }
    }

    private var visibilityObserver: NSObjectProtocol?

    /// Only start the show when someone can see it: the window must be on the active Space and not covered.
    private func playWhenVisible() {
        guard let window else { return }
        if window.isVisible, window.isOnActiveSpace, window.occlusionState.contains(.visible) {
            play()
            return
        }
        guard visibilityObserver == nil else { return }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.occlusionState.contains(.visible) else { return }
                if let o = self.visibilityObserver { NotificationCenter.default.removeObserver(o) }
                self.visibilityObserver = nil
                self.autoPlayTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(0.6))
                    guard !Task.isCancelled else { return }
                    self?.playWhenVisible()
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) { play() }
    override func accessibilityPerformPress() -> Bool { play(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var reduceMotion: Bool {
        Self.testing.forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func play() {
        guard runner == nil, !resetting, let window, let screen = window.screen, bounds.width > 0 else { return }
        layoutSubtreeIfNeeded()
        if isFinal {
            resetToIcon { [weak self] in self?.play() }
            return
        }
        onStart?()
        if reduceMotion {
            playReducedMotion()
            return
        }
        let home = homeInScreenLocal(screen: screen)
        let trash = Self.testing.forceNoTrash
            ? nil
            : TrashLocator.trash(on: screen, useAccessibility: !Self.testing.skipAccessibility)
        let fakeDock = trash == nil ? FakeDock.layout(on: screen) : nil
        let geometry = HeroGeometry(screen: screen, home: home, radius: bubbleRadius, bodyHalf: bodyHalf,
                                    trash: trash ?? fakeDock?.trash)
        let choreography = HeroChoreography(geometry)
        let runner = HeroRunner(choreography: choreography, screen: screen, hero: self, fakeDock: fakeDock)
        self.runner = runner
        runner.start()
    }

    /// Orb centre at rest in screen-local points (y up), recomputed every frame so everything near the window
    /// follows it if it's dragged mid-animation.
    func homeInScreenLocal(screen: NSScreen) -> CGPoint {
        guard let window else { return .zero }
        let onScreen = window.convertPoint(toScreen: convert(bubbleCenterInView, to: nil))
        return CGPoint(x: onScreen.x - screen.frame.minX, y: onScreen.y - screen.frame.minY)
    }

    // MARK: Driven by the runner

    func setRestingOrbVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    func applyIcon(_ f: HeroFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileLayer.opacity = f.tileInWindow ? 1 : 0
        var t = CATransform3DMakeTranslation(0, f.tileDY, 0)
        t = CATransform3DScale(t, f.tileScale.width, f.tileScale.height, 1)
        tileLayer.transform = t
        glowLayer.opacity = Float(max(0, min(1, f.glow)))
        bloomLayer.opacity = Float(max(0, min(1, f.bloom)))
        CATransaction.commit()
        applyCaption(f.caption)
    }

    private var captionProgress: CGFloat = -1
    private func applyCaption(_ p: CGFloat) {
        guard showsCaption, p != captionProgress else { return }
        captionProgress = p
        let e = CGFloat(HeroChoreography.easeOut(Double(p)))
        caption.alphaValue = e
        caption.frame.origin.y = -7 * (1 - e)
    }

    func sayHello() {
        setAccessibilityLabel("Wisp: " + Self.captionText)
        onHello?()
        guard showsCaption else { return }
        // VoiceOver hears the caption too (posted after this frame so it can't cost one).
        Task { @MainActor [weak self] in
            guard let self else { return }
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: Self.captionText, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func runnerDidFinish(at t: Double, choreography: HeroChoreography?) {
        runner = nil
        enterFinalState(animated: true, at: t, choreography: choreography)
    }

    /// The orb hovering where the icon was, its colourful shadow breathing underneath, caption shown.
    private func enterFinalState(animated: Bool, at t: Double, choreography: HeroChoreography?) {
        isFinal = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileLayer.opacity = 0
        bloomLayer.opacity = 0
        bubbleLayer.opacity = 1
        bubbleLayer.removeAllAnimations()
        shadowLayer.removeAllAnimations()
        haloLayer.removeAllAnimations()
        let hover = hoverCenterInView
        bubbleLayer.position = hover
        bubbleLayer.transform = CATransform3DIdentity
        let idle = HeroChoreography.idle(phase: 0, radius: bubbleRadius)
        shadowLayer.position = CGPoint(x: hover.x, y: hover.y + idle.shadowDY)
        shadowLayer.transform = CATransform3DMakeScale(idle.shadowScale.width, idle.shadowScale.height, 1)
        shadowLayer.opacity = Float(idle.shadowOpacity)
        haloLayer.position = hover
        haloLayer.transform = CATransform3DMakeScale(HeroChoreography.haloScale, HeroChoreography.haloScale, 1)
        haloLayer.opacity = Float(HeroChoreography.haloOpacity)
        CATransaction.commit()
        applyCaption(1)
        guard animated, let choreography else { return }
        // Continue the hover exactly where the panel left it (same functions, same phase).
        let period = 1 / HeroChoreography.bobFrequency
        let n = 90
        var dy: [NSValue] = [], shadowT: [NSValue] = [], shadowO: [NSNumber] = [], orbT: [NSValue] = []
        for i in 0...n {
            let ph = Double(i) / Double(n)
            let s = HeroChoreography.idle(phase: ph, radius: bubbleRadius)
            dy.append(NSValue(point: CGPoint(x: 0, y: s.orbDY)))
            orbT.append(NSValue(caTransform3D: CATransform3DMakeAffineTransform(s.orbShape)))
            shadowT.append(NSValue(caTransform3D: CATransform3DMakeScale(s.shadowScale.width, s.shadowScale.height, 1)))
            shadowO.append(NSNumber(value: Double(s.shadowOpacity)))
        }
        let offset = (t - choreography.tBob0).truncatingRemainder(dividingBy: period)
        func loop(_ key: String, _ values: [Any], additive: Bool = false) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.duration = period
            a.repeatCount = .infinity
            a.isAdditive = additive
            a.timeOffset = offset
            a.calculationMode = .linear
            return a
        }
        bubbleLayer.add(loop("position", dy, additive: true), forKey: "bob")
        bubbleLayer.add(loop("transform", orbT), forKey: "breathe")
        haloLayer.add(loop("position", dy, additive: true), forKey: "bob")
        shadowLayer.add(loop("transform", shadowT), forKey: "breathe")
        shadowLayer.add(loop("opacity", shadowO), forKey: "fade")
        // Shimmering film: a slow hue drift that leaves the white highlights alone.
        let huePeriod = 1 / HeroChoreography.hueFrequency
        var hues: [NSNumber] = []
        for i in 0...n { hues.append(NSNumber(value: HeroChoreography.hue(phase: Double(i) / Double(n), amplitude: HeroChoreography.hueFinal))) }
        let h = CAKeyframeAnimation(keyPath: "filters.hue.inputAngle")
        h.values = hues
        h.duration = huePeriod
        h.repeatCount = .infinity
        h.timeOffset = (t - choreography.tHue0).truncatingRemainder(dividingBy: huePeriod)
        bubbleLayer.add(h, forKey: "shimmer")
    }

    /// Replay from the final state: the squircle comes back and the orb settles into it, then the show starts.
    private func resetToIcon(then next: @escaping @MainActor () -> Void) {
        resetting = true
        isFinal = false
        let d = 0.45
        CATransaction.begin()
        CATransaction.setAnimationDuration(d)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1))
        for l in [bubbleLayer, shadowLayer, haloLayer] { l.removeAllAnimations() }
        bubbleLayer.setValue(0, forKeyPath: "filters.hue.inputAngle")
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: bubbleLayer.position)
        move.toValue = NSValue(point: bubbleCenterInView)
        bubbleLayer.add(move, forKey: "home")
        bubbleLayer.position = bubbleCenterInView
        for (l, to) in [(tileLayer, Float(1)), (glowLayer, 1), (shadowLayer, 0), (haloLayer, 0)] {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity
            a.toValue = to
            l.add(a, forKey: "fade")
            l.opacity = to
        }
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.9
        pop.toValue = 1
        tileLayer.add(pop, forKey: "pop")
        tileLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            caption.animator().alphaValue = 0
        }
        setAccessibilityLabel("Wisp")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(d + 0.35))
            self?.resetting = false
            next()
        }
    }

    /// Reduce Motion: no travel. The icon cross-fades to the final hovering orb (still), then the caption fades in.
    private func playReducedMotion() {
        let restCenter = bubbleCenterInView
        enterFinalState(animated: false, at: 0, choreography: nil)
        let d = 0.7
        let now = CACurrentMediaTime()
        func fade(_ l: CALayer, _ values: [Float], _ times: [NSNumber], key: String) {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values
            a.keyTimes = times
            a.duration = d
            a.beginTime = now
            a.fillMode = .backwards
            a.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            l.add(a, forKey: key)
        }
        // The orb dissolves out of the squircle and back in at its new place (no visible travel).
        fade(bubbleLayer, [1, 0, 1], [0, 0.45, 1], key: "dissolve")
        let place = CAKeyframeAnimation(keyPath: "position")
        place.values = [NSValue(point: restCenter), NSValue(point: hoverCenterInView)]
        place.keyTimes = [0, 0.45, 1]          // discrete: one more key time than values
        place.calculationMode = .discrete
        place.duration = d
        place.beginTime = now
        place.fillMode = .backwards
        bubbleLayer.add(place, forKey: "place")
        fade(tileLayer, [1, 0, 0], [0, 0.6, 1], key: "fadeOut")
        for l in [shadowLayer, haloLayer] { fade(l, [0, 0, l.opacity], [0, 0.45, 1], key: "fadeIn") }
        caption.alphaValue = 0
        captionProgress = 0
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(d * 0.8))
            guard let self else { return }
            self.sayHello()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.8
                self.caption.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }
}

// MARK: - Geometry

/// Everything the choreography needs to know about the world, in screen-local points (y up).
struct HeroGeometry {
    var screenSize: CGSize
    var visible: CGRect          // visibleFrame, screen-local
    var home: CGPoint            // orb centre at rest
    var radius: CGFloat          // orb radius
    var bodyHalf: CGFloat        // half the squircle body's side
    var trash: TrashTarget

    @MainActor
    init(screen: NSScreen, home: CGPoint, radius: CGFloat, bodyHalf: CGFloat, trash: TrashTarget?) {
        let o = screen.frame.origin
        screenSize = screen.frame.size
        visible = screen.visibleFrame.offsetBy(dx: -o.x, dy: -o.y)
        self.home = home
        self.radius = radius
        self.bodyHalf = bodyHalf
        // A Trash is always available: the real one, or the drawn Dock's (laid out in screen-local already).
        self.trash = trash ?? TrashTarget(iconRect: CGRect(x: screen.frame.width * 0.8, y: 8, width: 50, height: 50), isDrawn: true)
    }
}

/// The Trash's icon rect (screen-local or global, y up). The bin's opening: ~0.66 of the tile wide, its front lip
/// 0.24 tile above the icon centre (measured on the macOS 27 Trash icon in the Dock).
struct TrashTarget {
    var iconRect: CGRect
    var isDrawn: Bool
    var tile: CGFloat { iconRect.width }
    var mouth: CGPoint { CGPoint(x: iconRect.midX, y: iconRect.midY + tile * 0.24) }
    var openingWidth: CGFloat { tile * 0.66 }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> TrashTarget {
        TrashTarget(iconRect: iconRect.offsetBy(dx: dx, dy: dy), isDrawn: isDrawn)
    }
}

// MARK: - Choreography (pure)

/// One sampled frame.
struct HeroFrame {
    // The orb, relative to the live home (so it follows the window).
    var orb = CGPoint.zero
    var orbShape = CGAffineTransform.identity
    var orbHue: CGFloat = 0
    var orbOpacity: CGFloat = 1
    // Its colourful shadow (relative to live home) and glow.
    var shadow = CGPoint.zero
    var shadowScale = CGSize(width: 1, height: 1)
    var shadowOpacity: CGFloat = 0
    var halo: CGFloat = 0
    var haloScale: CGFloat = 1
    // The squircle while it's still in the window.
    var tileInWindow = true
    var tileDY: CGFloat = 0
    var tileScale = CGSize(width: 1, height: 1)
    var glow: CGFloat = 1
    var bloom: CGFloat = 0
    // The squircle in flight (screen-local, absolute; `tileFollow` of a live window move is added).
    var tileCenter = CGPoint.zero
    var tileFollow: CGFloat = 1
    var tileRotation: CGFloat = 0
    var tileShape = CGSize(width: 1, height: 1)
    var tileClip: CGRect?
    // The Trash and the Dock.
    var trashFull: CGFloat = 0            // drawn Dock only: its Trash fills up
    var trashGulp = CGSize(width: 1, height: 1)
    var lipRing: CGFloat = -1             // 0…1 progress of a glint ring spreading from the Trash's lip (-1: none)
    var lipRingStrength: CGFloat = 0
    var dockReveal: CGFloat = 0
    var caption: CGFloat = 0
}

struct Hop {
    let p0: CGPoint, p1: CGPoint
    let g: CGFloat, k: CGFloat
    let vx0: CGFloat, vy0: CGFloat
    let duration: Double

    /// Ballistic hop from p0 to p1 peaking `apex` above the higher end. `drag` (1/s) bleeds horizontal speed so the
    /// hop can arrive steeply.
    init(from p0: CGPoint, to p1: CGPoint, apex: CGFloat, g: CGFloat, drag k: CGFloat = 0) {
        self.p0 = p0; self.p1 = p1; self.g = g; self.k = k
        let top = max(p0.y, p1.y) + max(0.5, apex)
        vy0 = sqrt(2 * g * (top - p0.y))
        let t = Double(vy0 / g + sqrt(2 * (top - p1.y) / g))
        duration = t
        let dx = p1.x - p0.x
        vx0 = k > 1e-4 ? dx * k / (1 - exp(-k * CGFloat(t))) : dx / CGFloat(t)
    }

    func position(_ t: Double) -> CGPoint {
        let tt = CGFloat(t)
        let x = k > 1e-4 ? p0.x + vx0 * (1 - exp(-k * tt)) / k : p0.x + vx0 * tt
        return CGPoint(x: x, y: p0.y + vy0 * tt - g * tt * tt / 2)
    }

    func velocity(_ t: Double) -> CGVector {
        let tt = CGFloat(t)
        return CGVector(dx: k > 1e-4 ? vx0 * exp(-k * tt) : vx0, dy: vy0 - g * tt)
    }

    /// First time y crosses `y` on the way down.
    func timeDescending(to y: CGFloat) -> Double {
        let a = g / 2, b = -vy0, c = y - p0.y
        let disc = max(0, b * b - 4 * a * c)
        return Double((-b + sqrt(disc)) / (2 * a))
    }
}

struct HeroChoreography {
    // Tunables (points, seconds).
    static let gravity: CGFloat = 3000
    static let lift: CGFloat = 1.06            // the orb is a little closer to you once it's out
    static let hoverLift: CGFloat = 12          // final hover height above the orb's resting centre
    static let bobAmplitude: CGFloat = 2.6
    static let bobFrequency = 0.5
    static let hueFrequency = 0.14
    static let hueAct = 0.12, hueFinal = 0.30   // radians
    static let haloScale: CGFloat = 1.32
    static let haloOpacity: CGFloat = 0.34
    static func discSide(radius r: CGFloat) -> CGFloat { (4 * r).rounded() }

    let geo: HeroGeometry
    let r: CGFloat, body: CGFloat, dir: CGFloat
    let tileC: CGPoint                  // squircle centre relative to home
    let topY: CGFloat                   // squircle top surface relative to home
    let crouch: CGFloat = 0.13
    let p45: CGPoint, kickSpot: CGPoint, onTop: CGPoint
    let hopPop: Hop, hopDrop: Hop, hopOff: Hop, hopTile: Hop
    let reboundV: CGFloat
    let boxSquash: CGFloat
    let tileScaleInTrash: CGFloat
    let clip: CGRect
    let tileStart: CGPoint              // absolute

    // Marks
    let tPop = 0.72
    let tSock: Double, tRebound: Double, tGlide: Double, tHold: Double, tDrop: Double
    let tBox1: Double, tBox2: Double, tBox3: Double, tOnTop: Double, tHopOff: Double
    let tCatch: Double, tWind: Double, tRam: Double, tImpact: Double, tRecoil: Double
    let tTileLaunch: Double, tRim: Double, tEntry: Double, tTileGone: Double
    let rimY: CGFloat, rimBounceV: CGFloat, insideY: CGFloat
    let tFloat: Double, tHome: Double, tBob0: Double, tHue0: Double
    let tHello: Double, tDockHide: Double, tEnd: Double
    let floatFrom: CGPoint
    var helloTime: Double { tHello }
    var duration: Double { tEnd }

    static let sockContact = 0.065, box1Contact = 0.07, box2Contact = 0.05
    static let glideTime = 0.44, holdTime = 0.06, lookTime = 0.22, catchTime = 0.07
    static let windTime = 0.22, windHold = 0.09, ramTime = 0.075, impactTime = 0.06
    static let floatTime = 0.78, captionTime = 1.1, dockIn = 0.55, dockOut = 0.45
    static let tileGravity: CGFloat = 2300      // the squircle recedes into depth, so it reads a little floatier
    static let rimContact = 0.08, rimBounce: CGFloat = 11
    static let windPull: CGFloat = 16

    init(_ geo: HeroGeometry) {
        self.geo = geo
        let g = Self.gravity, L = Self.lift
        r = geo.radius
        body = geo.bodyHalf
        let home = geo.home
        dir = geo.trash.mouth.x >= home.x ? 1 : -1
        tileC = CGPoint(x: 0, y: -0.8 * r / 29.25)
        topY = tileC.y + body
        let headroom = geo.visible.maxY - home.y

        // 1–2. Pop out of the socket and fall back in for one small bounce.
        let crouchPos = CGPoint(x: 0, y: -r * crouch - 1)
        let socketRest = CGPoint(x: 0, y: r * (L - 1))
        hopPop = Hop(from: crouchPos, to: socketRest, apex: min(34, headroom - r - 20), g: g)
        tSock = tPop + hopPop.duration
        tRebound = tSock + Self.sockContact
        let reboundH: CGFloat = 14
        reboundV = sqrt(2 * g * reboundH)
        tGlide = tRebound + Double(reboundV / g)
        // 3. Glide up and away at 45° (counter-clockwise from straight up when the Trash is to the right).
        let reach = min(112, headroom - r * L - 16)
        p45 = CGPoint(x: -dir * reach * 0.7071, y: socketRest.y + reboundH + reach * 0.7071 - 8)
        tHold = tGlide + Self.glideTime
        tDrop = tHold + Self.holdTime
        // 4. Drop onto the top of the squircle; two bounces there.
        onTop = CGPoint(x: 0, y: topY + r * L)
        hopDrop = Hop(from: p45, to: onTop, apex: 18, g: g, drag: 2.2)
        tBox1 = tDrop + hopDrop.duration
        boxSquash = min(0.2, max(0.08, abs(hopDrop.velocity(hopDrop.duration).dy) / 2600))
        tBox2 = tBox1 + Self.box1Contact + 2 * sqrt(2 * 9 / Double(g))
        tBox3 = tBox2 + Self.box2Contact + 2 * sqrt(2 * 2.5 / Double(g))
        tOnTop = tBox3
        tHopOff = tOnTop + Self.lookTime
        // 5. Hop off the side away from the Trash, wind up, ram the squircle.
        kickSpot = CGPoint(x: -dir * (body + r * L + 16), y: tileC.y + 8)
        hopOff = Hop(from: onTop, to: kickSpot, apex: 14, g: g)
        tCatch = tHopOff + hopOff.duration
        tWind = tCatch + Self.catchTime
        tRam = tWind + Self.windTime + Self.windHold
        tImpact = tRam + Self.ramTime
        tRecoil = tImpact + Self.impactTime
        tTileLaunch = tImpact + 0.025
        // The squircle's flight into the Trash: shrinks to fit the opening, one full turn, enters upright.
        let trash = geo.trash
        tileStart = CGPoint(x: home.x + tileC.x, y: home.y + tileC.y)
        tileScaleInTrash = max(0.22, min(0.6, 0.86 * trash.openingWidth / (2 * body)))
        // Lands on the Trash's rim (squash, the bin flinches), hops a little and drops in.
        let gs = Self.tileGravity
        let half = body * tileScaleInTrash
        rimY = trash.mouth.y + half
        insideY = trash.mouth.y - half * 1.7
        let apexS = max(24, min(80, geo.visible.maxY - (tileStart.y + body) - 12))
        hopTile = Hop(from: tileStart, to: CGPoint(x: trash.mouth.x, y: rimY), apex: apexS, g: gs, drag: 0.35)
        tRim = tTileLaunch + hopTile.duration
        rimBounceV = sqrt(2 * gs * Self.rimBounce)
        let up = Double(rimBounceV / gs)
        let top = trash.mouth.y + half + Self.rimBounce
        tEntry = tRim + Self.rimContact + up + sqrt(2 * Double(top - (trash.mouth.y - half * 0.9)) / Double(gs))
        tTileGone = tRim + Self.rimContact + up + sqrt(2 * Double(top - (trash.mouth.y - half * 1.7)) / Double(gs))
        let w = trash.tile * 0.80
        clip = CGRect(x: trash.mouth.x - w / 2, y: trash.mouth.y - 600, width: w, height: 600)
        // 6. The orb floats back to take the icon's place, hovers; caption.
        tFloat = max(tRecoil + 0.35, tRim + 0.06)
        tHome = tFloat + Self.floatTime
        tBob0 = tHome - 0.30
        tHue0 = tPop
        tHello = tHome - 0.05
        tDockHide = tEntry + 0.9
        tEnd = max(tHello + Self.captionTime, trash.isDrawn ? tDockHide + Self.dockOut : 0) + 0.05
        floatFrom = CGPoint.zero
    }

    // MARK: Shape helpers

    /// Volume-preserving (3-D) squash/stretch along an axis at `theta`: `s` > 0 stretches, < 0 squashes.
    static func axis(_ theta: CGFloat, _ s: CGFloat) -> CGAffineTransform {
        let along = max(0.3, 1 + s)
        return CGAffineTransform(rotationAngle: -theta)
            .concatenating(CGAffineTransform(scaleX: along, y: 1 / sqrt(along)))
            .concatenating(CGAffineTransform(rotationAngle: theta))
    }
    static func vertical(_ s: CGFloat) -> CGAffineTransform { axis(.pi / 2, s) }
    static func horizontal(_ s: CGFloat) -> CGAffineTransform { axis(0, s) }

    /// Stretch along the velocity (a motion-blur substitute), saturating at `maxStretch`.
    static func along(_ v: CGVector, maxStretch: CGFloat = 0.18, v0: CGFloat = 1100) -> CGAffineTransform {
        let speed = hypot(v.dx, v.dy)
        guard speed > 1 else { return .identity }
        return axis(atan2(v.dy, v.dx), maxStretch * (1 - exp(-speed / v0)))
    }

    static func lerp(_ a: CGAffineTransform, _ b: CGAffineTransform, _ t: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t,
                          c: a.c + (b.c - a.c) * t, d: a.d + (b.d - a.d) * t, tx: 0, ty: 0)
    }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// Damped ringing after a kick: starts at 0, first swings toward the sign of `amp`.
    static func ring(_ t: Double, amp: CGFloat, freq: Double, decay: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        return amp * CGFloat(exp(-t / decay) * sin(2 * .pi * freq * t))
    }
    /// Non-negative bump train (for "gulps" that must never shrink below the original).
    static func bumps(_ t: Double, amp: CGFloat, freq: Double, decay: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        let s = sin(.pi * freq * t)
        return amp * CGFloat(exp(-t / decay) * s * s)
    }
    /// Fast attack, exponential release (0…1 peak).
    static func pulse(_ t: Double, attack: Double, release: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        if t < attack { return CGFloat(smooth(t / attack)) }
        return CGFloat(exp(-(t - attack) / release))
    }
    static func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
    static func easeInOut(_ x: Double) -> Double {
        let c = min(1, max(0, x)); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
    static func easeOut(_ x: Double) -> Double { let c = min(1, max(0, x)); return 1 - pow(1 - c, 3) }
    static func easeIn(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c }
    /// SwiftUI `spring(duration:bounce:)` step response, 0 → 1.
    static func spring(_ t: Double, duration: Double, bounce: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * .pi / duration
        let zeta = 1 - bounce
        if zeta >= 1 { return 1 - (1 + w0 * t) * exp(-w0 * t) }
        let wd = w0 * sqrt(1 - zeta * zeta)
        return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
    }
    static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        let v = 1 - u
        return CGPoint(x: v * v * a.x + 2 * v * u * c.x + u * u * b.x, y: v * v * a.y + 2 * v * u * c.y + u * u * b.y)
    }

    // MARK: Idle hover (shared with the view's looping animations)

    struct Idle {
        var orbDY: CGFloat
        var orbShape: CGAffineTransform
        var shadowDY: CGFloat
        var shadowScale: CGSize
        var shadowOpacity: CGFloat
    }

    /// One bob cycle, phase 0…1. The shadow sits on an imaginary floor under the orb: it tightens and darkens as the
    /// orb sinks toward it, spreads and fades as it rises.
    static func idle(phase: Double, radius r: CGFloat, amplitude: CGFloat = 1) -> Idle {
        let s = CGFloat(sin(2 * .pi * phase))
        let c = CGFloat(cos(2 * .pi * phase))
        let dy = bobAmplitude * amplitude * s
        let h = s * amplitude            // -1 (low) … 1 (high)
        return Idle(orbDY: dy,
                    orbShape: vertical(0.012 * c * amplitude),
                    shadowDY: -(r + 15),
                    shadowScale: CGSize(width: 0.98 - 0.07 * h, height: 0.25 - 0.015 * h),
                    shadowOpacity: 0.78 - 0.14 * h)
    }

    static func hue(phase: Double, amplitude: Double) -> CGFloat {
        CGFloat(amplitude * sin(2 * .pi * phase))
    }

    // MARK: Sampling

    func sample(_ t: Double) -> HeroFrame {
        var f = HeroFrame()
        let L = Self.lift
        var pos = CGPoint.zero
        var shape = CGAffineTransform.identity
        var lift: CGFloat = 1
        var wobble: CGFloat = 0            // vertical jelly mode
        var wobbleX: CGFloat = 0           // horizontal jelly mode (after the ram)
        var z: CGFloat = 0                 // how far the orb has come out toward you (shadow separation)
        var floorMode: CGFloat = 0         // 0: shadow on the window behind; 1: hover shadow underneath

        // Rings that carry across phases.
        wobble += Self.ring(t - tSock - Self.sockContact, amp: 0.07, freq: 6.0, decay: 0.10)
        wobble += Self.ring(t - tBox1 - Self.box1Contact, amp: boxSquash * 0.6, freq: 6.0, decay: 0.11)
        wobble += Self.ring(t - tCatch, amp: -0.05, freq: 5.0, decay: 0.10)
        wobbleX += Self.ring(t - tRecoil, amp: 0.12, freq: 5.5, decay: 0.12)

        if t < tPop {
            // Wake: a twitch, a beat, a jiggle, a crouch.
            wobble += Self.ring(t - 0.02, amp: 0.05, freq: 5.0, decay: 0.10)
            var dx: CGFloat = 0
            let j0 = 0.27, jl = 0.34
            if t > j0 && t < j0 + jl {
                let p = (t - j0) / jl
                let env = CGFloat(sin(.pi * p))
                wobble += 0.06 * env * CGFloat(sin(2 * .pi * 5.4 * (t - j0)))
                dx += 1.4 * env * CGFloat(sin(2 * .pi * 2.7 * (t - j0)))
            }
            let c = CGFloat(Self.easeInOut((t - 0.52) / ((tPop - 0.52) * 0.85)))
            let sy = (1 + wobble) * (1 - crouch * c)
            shape = Self.vertical(sy - 1)
            wobble = 0
            pos = CGPoint(x: dx, y: r * (sy - 1) - 1 * c)
            f.tileScale = CGSize(width: 1 - 0.01 * c, height: 1 - 0.016 * c)
            f.tileDY = -0.9 * c
            f.bloom = 0.16 * Self.pulse(t - 0.02, attack: 0.05, release: 0.18) + 0.28 * c
        } else if t < tSock {
            // Pop: out of the socket (stretching up), then back down.
            let ht = t - tPop
            pos = hopPop.position(ht)
            let v = hopPop.velocity(ht)
            lift = 1 + (L - 1) * CGFloat(Self.smooth(ht / 0.12))
            z = CGFloat(Self.smooth(ht / 0.14))
            let blend = CGFloat(Self.smooth(ht / 0.05))
            let taper = CGFloat(Self.smooth((hopPop.duration - ht) / 0.035))
            shape = Self.lerp(Self.vertical(-crouch), Self.lerp(.identity, Self.along(v), taper), blend)
        } else if t < tRebound {
            // Small bounce in the socket.
            let u = (t - tSock) / Self.sockContact
            let sy = 1 - 0.13 * CGFloat(sin(.pi * u))
            lift = L
            shape = Self.vertical(sy - 1)
            pos = CGPoint(x: 0, y: -r + r * L * sy)
            z = 0.75
        } else if t < tGlide {
            let ht = t - tRebound
            let v = reboundV - Self.gravity * CGFloat(ht)
            pos = CGPoint(x: 0, y: r * (L - 1) + reboundV * CGFloat(ht) - Self.gravity * CGFloat(ht * ht) / 2)
            lift = L
            shape = Self.along(CGVector(dx: 0, dy: v))
            z = 0.75 + 0.25 * CGFloat(Self.smooth(ht / 0.1))
        } else if t < tDrop {
            // Glide to the 45° spot, overshoot a hair, hold.
            let a = CGPoint(x: 0, y: r * (L - 1) + 14)
            let ctrl = CGPoint(x: a.x + (p45.x - a.x) * 0.15, y: p45.y + 6)
            let gt = t - tGlide
            let u = CGFloat(Self.spring(gt, duration: Self.glideTime * 1.25, bounce: 0.18))
            pos = Self.quad(a, ctrl, p45, u)
            let u2 = CGFloat(Self.spring(gt + 1.0 / 240, duration: Self.glideTime * 1.25, bounce: 0.18))
            let p2 = Self.quad(a, ctrl, p45, u2)
            shape = Self.along(CGVector(dx: (p2.x - pos.x) * 240, dy: (p2.y - pos.y) * 240), maxStretch: 0.12, v0: 700)
            pos.y += Self.ring(t - tHold + 0.05, amp: 1.0, freq: 1.4, decay: 0.4)
            lift = L
            z = 1
        } else if t < tBox1 {
            // Drop onto the squircle.
            let ht = t - tDrop
            pos = hopDrop.position(ht)
            let taper = CGFloat(Self.smooth((hopDrop.duration - ht) / 0.035))
            shape = Self.lerp(.identity, Self.along(hopDrop.velocity(ht)), taper * CGFloat(Self.smooth(ht / 0.05)))
            lift = L
            z = 1
        } else if t < tOnTop + Self.lookTime {
            lift = L
            z = 1
            let base = topY
            if t < tBox1 + Self.box1Contact {
                let u = (t - tBox1) / Self.box1Contact
                let sy = 1 - boxSquash * CGFloat(sin(.pi * u))
                shape = Self.vertical(sy - 1)
                wobble = 0
                pos = CGPoint(x: 0, y: base + r * L * sy)
            } else if t < tBox2 {
                let ht = t - tBox1 - Self.box1Contact
                let v0 = sqrt(2 * Self.gravity * 9)
                pos = CGPoint(x: 0, y: onTop.y + v0 * CGFloat(ht) - Self.gravity * CGFloat(ht * ht) / 2)
                shape = Self.along(CGVector(dx: 0, dy: v0 - Self.gravity * CGFloat(ht)), maxStretch: 0.10)
            } else if t < tBox2 + Self.box2Contact {
                let u = (t - tBox2) / Self.box2Contact
                let sy = 1 - 0.06 * CGFloat(sin(.pi * u))
                shape = Self.vertical(sy - 1)
                wobble = 0
                pos = CGPoint(x: 0, y: base + r * L * sy)
            } else if t < tBox3 {
                let ht = t - tBox2 - Self.box2Contact
                let v0 = sqrt(2 * Self.gravity * 2.5)
                pos = CGPoint(x: 0, y: onTop.y + v0 * CGFloat(ht) - Self.gravity * CGFloat(ht * ht) / 2)
            } else {
                // Look toward the Trash.
                let p = Self.easeInOut((t - tOnTop) / Self.lookTime * 1.4)
                pos = CGPoint(x: dir * 2.5 * CGFloat(p), y: onTop.y)
                shape = Self.axis(dir > 0 ? 0 : .pi, 0.05 * CGFloat(p))
                // Keep the bottom on the box while leaning.
                pos.y = base + r * L * (shape.d)
            }
        } else if t < tCatch {
            // Hop off the far side.
            let ht = t - tHopOff
            pos = hopOff.position(ht)
            pos.x += dir * 2.5 * CGFloat(1 - Self.smooth(ht / 0.1))
            shape = Self.lerp(.identity, Self.along(hopOff.velocity(ht)), CGFloat(Self.smooth(ht / 0.04)))
            lift = L
            z = 1
        } else if t < tRam {
            // Catch itself in the air, then wind up (pull back, squash along the kick axis).
            lift = L
            z = 1
            let ct = t - tCatch
            let brake = Self.ring(ct, amp: -3.0, freq: 3.0, decay: 0.08)
            let w = CGFloat(Self.easeInOut((t - tWind) / Self.windTime))
            // Fully wound: a tiny tremble, like a held breath.
            let held = t - tWind - Self.windTime
            let tremble: CGFloat = held > 0 ? 0.7 * CGFloat(sin(2 * .pi * 19 * held)) : 0
            pos = CGPoint(x: kickSpot.x - dir * Self.windPull * w + tremble, y: kickSpot.y + brake + 2.5 * w)
            shape = Self.horizontal(-0.15 * w)
        } else if t < tImpact {
            // Ram.
            lift = L
            z = 1
            let u = (t - tRam) / Self.ramTime
            let from = kickSpot.x - dir * Self.windPull
            let contactX = -dir * (body + r * L)
            pos = CGPoint(x: Self.lerp(from, contactX, CGFloat(Self.easeIn(u))), y: kickSpot.y + Self.lerp(2.5, 0, CGFloat(u)))
            shape = Self.horizontal(Self.lerp(-0.15, 0.07, CGFloat(Self.smooth(u * 1.5))))
        } else if t < tRecoil {
            // Impact: flattened against the squircle's side.
            lift = L
            z = 1
            let u = (t - tImpact) / Self.impactTime
            let sx = 1 - 0.24 * CGFloat(sin(.pi * u))
            shape = Self.horizontal(sx - 1)
            wobble = 0
            pos = CGPoint(x: -dir * body - dir * r * L * sx, y: kickSpot.y)
        } else if t < tFloat {
            // Bounce back off it and watch the squircle fly.
            lift = L
            z = 1
            let rt = t - tRecoil
            let back = 18 * CGFloat(1 - exp(-rt / 0.12))
            pos = CGPoint(x: -dir * (body + r * L) - dir * back, y: kickSpot.y)
            let tile = tilePosition(t)
            let look = CGVector(dx: tile.x - (geo.home.x + pos.x), dy: tile.y - (geo.home.y + pos.y))
            let lean = CGFloat(Self.smooth(rt / 0.3))
            shape = Self.axis(atan2(look.dy, look.dx), 0.045 * lean)
            pos.x += dir * 3 * lean
        } else {
            // Float home and hover.
            let watchEnd = watchPose()
            let ft = t - tFloat
            let u = CGFloat(Self.spring(ft, duration: Self.floatTime * 1.1, bounce: 0.14))
            let target = CGPoint(x: 0, y: Self.hoverLift)
            let ctrl = CGPoint(x: watchEnd.x * 0.35, y: max(watchEnd.y, target.y) + 30)
            pos = Self.quad(watchEnd, ctrl, target, u)
            lift = Self.lerp(L, 1, CGFloat(Self.smooth(ft / Self.floatTime)))
            let leanOut = 1 - CGFloat(Self.smooth(ft / 0.3))
            shape = Self.axis(0, 0.03 * leanOut)
            floorMode = CGFloat(Self.smooth(ft / Self.floatTime))
            z = 1
        }

        // Hover bob (ramps in as the orb arrives) — shared with the view's idle loop.
        var idleShadow: Idle?
        if t > tBob0 {
            let amp = CGFloat(Self.smooth((t - tBob0) / 0.6))
            let phase = ((t - tBob0) * Self.bobFrequency).truncatingRemainder(dividingBy: 1)
            let idle = Self.idle(phase: phase, radius: r, amplitude: amp)
            pos.y += idle.orbDY
            shape = shape.concatenating(idle.orbShape)
            idleShadow = idle
        }

        f.orb = pos
        f.orbShape = Self.vertical(wobble).concatenating(Self.horizontal(wobbleX)).concatenating(shape)
            .concatenating(CGAffineTransform(scaleX: lift, y: lift))
        let hueAmp = t < tPop ? 0 : (t < tHome ? Self.hueAct : Self.lerp(CGFloat(Self.hueAct), CGFloat(Self.hueFinal), CGFloat(Self.smooth((t - tHome) / 1.0))))
        f.orbHue = Self.hue(phase: ((t - tHue0) * Self.hueFrequency).truncatingRemainder(dividingBy: 1), amplitude: Double(hueAmp))

        // Colourful shadow. Behind (on the window): drops away and stretches as the orb comes out toward you.
        // Underneath (final): sits on an imaginary floor below the hovering orb.
        let behindOffset = CGPoint(x: 2 * z, y: -(5 + 9 * z))
        let behindScale = CGSize(width: 1 + 0.08 * z, height: 0.92 + 0.24 * z)
        let behindOpacity = 0.72 * z
        let floor = idleShadow ?? Self.idle(phase: 0, radius: r, amplitude: 0)
        let floorPos = CGPoint(x: pos.x, y: Self.hoverLift + floor.shadowDY)
        let behindPos = CGPoint(x: pos.x + behindOffset.x, y: pos.y + behindOffset.y)
        let m = floorMode
        f.shadow = Self.lerp(behindPos, floorPos, m)
        f.shadowScale = CGSize(width: Self.lerp(behindScale.width, floor.shadowScale.width, m) * lift,
                               height: Self.lerp(behindScale.height, floor.shadowScale.height, m) * lift)
        f.shadowOpacity = Self.lerp(behindOpacity, floor.shadowOpacity, m)
        // The glow comes back as the orb settles in its new place.
        f.halo = Self.haloOpacity * CGFloat(Self.smooth((t - tHome + 0.4) / 0.7))
            + 0.25 * Self.pulse(t - tHome + 0.15, attack: 0.12, release: 0.35)
        f.haloScale = Self.haloScale * lift

        // The squircle.
        let d = hypot(pos.x, pos.y)
        f.glow = 1 - CGFloat(Self.smooth(Double((d - 3) / (r * 1.4))))
        if t < tPop { f.glow = 1 }
        f.bloom += 0.5 * Self.pulse(t - tPop, attack: 0.03, release: 0.2)
        f.bloom *= max(f.glow, t < tPop + 0.05 ? 1 : 0)
        if t >= tPop && t < tImpact {
            // Recoil when the orb leaves, dips when it lands in the socket and on the top.
            let pop = Self.ring(t - tPop, amp: 2.2, freq: 4.2, decay: 0.12)
            let sock = Self.ring(t - tSock, amp: 1.6, freq: 4.5, decay: 0.10)
            let box1 = Self.ring(t - tBox1, amp: 3.2, freq: 4.0, decay: 0.12)
            let box2 = Self.ring(t - tBox2, amp: 1.2, freq: 4.5, decay: 0.10)
            let press = box1 + box2
            f.tileDY = -(pop + sock + press * 0.6)
            f.tileScale = CGSize(width: 1 - 0.008 * pop + 0.006 * press, height: 1 - 0.008 * pop - 0.012 * press)
            // Leaning on it while looking.
            if t > tBox3 && t < tCatch {
                f.tileScale.height -= 0.006 * CGFloat(Self.smooth((t - tBox3) / 0.1)) * CGFloat(1 - Self.smooth((t - tHopOff) / 0.08))
            }
        }
        f.tileInWindow = t < tImpact
        f.tileCenter = tilePosition(t)
        f.tileFollow = 1 - CGFloat(Self.smooth((t - tTileLaunch) / 0.2))
        if t >= tImpact {
            let tt = max(0, t - tTileLaunch)
            let u = min(1, tt / (tRim - tTileLaunch))
            // One full turn in the air, upright when it reaches the rim; a little tip into the bin on the bounce.
            let tip = t > tRim ? -dir * 0.16 * CGFloat(sin(.pi * min(1, (t - tRim) / (tEntry - tRim)))) : 0
            f.tileRotation = -dir * 2 * .pi * CGFloat(u) + tip
            let s = Self.lerp(1, tileScaleInTrash, CGFloat(Self.easeInOut(u)))
            // Hit (squashed sideways by the orb), then squashed by the landing on the rim.
            let hit = Self.pulse(t - tImpact, attack: 0.03, release: 0.06)
            var rim: CGFloat = 0
            if t >= tRim && t < tRim + Self.rimContact { rim = CGFloat(sin(.pi * (t - tRim) / Self.rimContact)) }
            f.tileShape = CGSize(width: s * (1 - 0.07 * hit + 0.14 * rim), height: s * (1 + 0.03 * hit - 0.20 * rim))
            if rim > 0 { f.tileCenter.y = rimY - body * s * (1 - (1 - 0.20 * rim)) }
            f.tileClip = clip
        }
        // The Trash reacts: a glint spreads from its lip on the rim hit and again (stronger) as it swallows the
        // squircle. The drawn Dock's own Trash also gulps and fills up; the real one can't be touched (and the
        // Dock draws it in its own style, so it's never covered with a look-alike).
        let ringLife = 0.38
        if t >= tEntry - 0.02 && t < tEntry - 0.02 + ringLife {
            f.lipRing = CGFloat((t - tEntry + 0.02) / ringLife); f.lipRingStrength = 1
        } else if t >= tRim && t < tRim + ringLife {
            f.lipRing = CGFloat((t - tRim) / ringLife); f.lipRingStrength = 0.35
        }
        if geo.trash.isDrawn {
            f.trashFull = CGFloat(Self.smooth((t - tEntry) / 0.08))
            let gulp = 0.4 * Self.bumps(t - tRim, amp: 1, freq: 3.0, decay: 0.10)
                + Self.bumps(t - tEntry, amp: 1, freq: 2.6, decay: 0.16)
            f.trashGulp = CGSize(width: 1 + 0.12 * gulp, height: 1 + 0.07 * gulp)
        }
        // The drawn Dock slides up when the orb lands on the box, and away after the Trash has gulped.
        if geo.trash.isDrawn {
            let inn = Self.spring(t - tBox1, duration: Self.dockIn, bounce: 0.12)
            let out = Self.easeIn((t - tDockHide) / Self.dockOut)
            f.dockReveal = CGFloat(inn * (1 - out))
        }
        f.caption = CGFloat(min(1, max(0, (t - tHello) / Self.captionTime)))
        return f
    }

    /// The squircle's centre (screen-local, absolute) — at rest until the kick, then its flight.
    func tilePosition(_ t: Double) -> CGPoint {
        guard t >= tTileLaunch else { return tileStart }
        if t < tRim { return hopTile.position(t - tTileLaunch) }
        let x = hopTile.p1.x
        if t < tRim + Self.rimContact { return CGPoint(x: x, y: rimY) }
        let bt = CGFloat(t - tRim - Self.rimContact)
        let y = rimY + rimBounceV * bt - Self.tileGravity * bt * bt / 2
        return CGPoint(x: x, y: max(insideY, y))
    }

    private func watchPose() -> CGPoint {
        let rt = tFloat - tRecoil
        let back = 18 * CGFloat(1 - exp(-rt / 0.12))
        return CGPoint(x: -dir * (body + r * Self.lift) - dir * back + dir * 3, y: kickSpot.y)
    }
}

// MARK: - Runner

/// Plays a choreography: a transparent, click-through panel over the window's screen (above the Dock) carries the
/// orb, its shadow and glow, the flying squircle and the Trash's reaction (and the drawn Dock when needed); the
/// icon's own layers are driven in the window until the kick. Frames come from a display link and are computed from
/// the clock, so a late frame never slows the motion down.
@MainActor
final class HeroRunner: NSObject {
    private let choreography: HeroChoreography
    private let screen: NSScreen
    private weak var hero: WelcomeHeroView?
    private let fakeDock: FakeDock?
    private let panel: NSPanel
    private let container = CALayer()
    private let tileHolder = CALayer()        // clips at the Trash's lip: the squircle disappears into the bin
    private var holderRect = CGRect.null
    private var warmupTicks = 0
    private var warmFrames = 0
    private let tile = CALayer()
    private let trashLayer = CALayer()       // full Trash over the real/drawn one
    private let drawnTrash = CALayer()       // the drawn Dock's empty Trash
    private let ring = CAShapeLayer()        // glint spreading from the Trash's lip
    private let shadow = CALayer()
    private let halo = CALayer()
    private let orb = CALayer()
    private var dockView: NSView?
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var helloSent = false
    private var handedOff = false
    private var finishing = false

    init(choreography: HeroChoreography, screen: NSScreen, hero: WelcomeHeroView, fakeDock: FakeDock?) {
        self.choreography = choreography
        self.screen = screen
        self.hero = hero
        self.fakeDock = fakeDock
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar                  // above the Dock
        // Opens on the active Space (where the welcome window is) and stays there if the user switches away.
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setFrame(screen.frame, display: false)
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layerUsesCoreImageFilters = true
        panel.contentView = content
        let scale = screen.backingScaleFactor
        let side = WelcomeHeroView.side

        if let fakeDock {
            let v = fakeDock.makeView(scale: scale)
            content.addSubview(v)
            dockView = v
        }
        // The stage is its own layer-hosting view above the drawn Dock, so the Trash and the squircle draw on top.
        container.frame = content.bounds
        let stage = NSView(frame: content.bounds)
        stage.layer = container
        stage.wantsLayer = true
        stage.layerUsesCoreImageFilters = true
        content.addSubview(stage)

        let trashRect = choreography.geo.trash.iconRect
        let trashPx = Int((trashRect.width * scale).rounded())
        for l in [drawnTrash, trashLayer] {
            l.anchorPoint = CGPoint(x: 0.5, y: 0)          // gulps grow up from the bottom
            l.bounds = CGRect(origin: .zero, size: trashRect.size)
            l.position = CGPoint(x: trashRect.midX, y: trashRect.minY)
            l.contentsScale = scale
            l.contentsGravity = .resize
        }
        drawnTrash.contents = WelcomeHeroAssets.trashIcon(full: false, pixels: trashPx)
        drawnTrash.opacity = fakeDock == nil ? 0 : 1
        trashLayer.contents = WelcomeHeroAssets.trashIcon(full: true, pixels: trashPx)
        trashLayer.opacity = 0
        let ow = choreography.geo.trash.openingWidth
        ring.path = CGPath(ellipseIn: CGRect(x: -ow / 2, y: -ow * 0.16, width: ow, height: ow * 0.32), transform: nil)
        ring.fillColor = NSColor.white.withAlphaComponent(0.10).cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 1.2
        ring.opacity = 0
        ring.contentsScale = scale

        tileHolder.frame = content.bounds
        tileHolder.masksToBounds = true          // a scissor clip: much cheaper than a full-screen mask
        tile.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        tile.contents = hero.squircleImage
        tile.contentsScale = scale
        tile.contentsGravity = .resize
        tile.minificationFilter = .trilinear
        tile.opacity = 0
        tileHolder.addSublayer(tile)

        let disc = HeroChoreography.discSide(radius: hero.bubbleRadius)
        for l in [shadow, halo] {
            l.bounds = CGRect(x: 0, y: 0, width: disc, height: disc)
            l.contents = hero.discImage
            l.contentsScale = scale
            l.opacity = 0
        }
        orb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        orb.anchorPoint = WelcomeHeroView.bubbleAnchor
        orb.contents = hero.bubbleImage
        orb.contentsScale = scale
        orb.contentsGravity = .resize
        orb.minificationFilter = .trilinear
        orb.filters = [WelcomeHeroView.hueFilter()]

        for l in [container, tileHolder, tile, trashLayer, drawnTrash, ring, shadow, halo, orb] as [CALayer] {
            l.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "path": NSNull(),
                         "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "contents": NSNull()]
        }
        // Back to front: drawn Trash, full Trash, flying squircle, orb's shadow, glow, orb.
        for l in [drawnTrash, trashLayer, tileHolder, ring, shadow, halo, orb] { container.addSublayer(l) }
    }

    func start() {
        apply(choreography.sample(0), t: 0)
        panel.orderFrontRegardless()
        let link = panel.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let hero, hero.window != nil else { cancel(); return }
        if let s = hero.window?.screen, s != screen { abort(); return }
        // The panel's first composites can be late: hold the clock (and keep the window's own orb showing — the two
        // copies are pixel-identical) for a few frames so the hand-over can't flash.
        if warmupTicks < 3 { warmupTicks += 1; return }
        if startTime == nil { startTime = link.timestamp }
        let t = link.targetTimestamp - (startTime ?? link.timestamp)
        WelcomeHeroView.testing.onTick?(t)
        if !handedOff {
            // The panel's orb is on screen now; hide the window's copy (identical pixels, so no flash).
            hero.setRestingOrbVisible(false)
            handedOff = true
        }
        if t >= choreography.helloTime && !helloSent {
            helloSent = true
            hero.sayHello()
        }
        if t >= choreography.duration {
            finish(at: t)
            return
        }
        let begin = CACurrentMediaTime()
        apply(choreography.sample(t), t: t)
        let ms = (CACurrentMediaTime() - begin) * 1000
        if ms > 4 { WelcomeHeroView.testing.onSlowFrame?(t, ms) }
    }

    private func apply(_ f: HeroFrame, t: Double) {
        guard let hero else { return }
        let home = hero.homeInScreenLocal(screen: screen)
        let drift = CGPoint(x: home.x - choreography.geo.home.x, y: home.y - choreography.geo.home.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orb.position = CGPoint(x: home.x + f.orb.x, y: home.y + f.orb.y)
        orb.transform = CATransform3DMakeAffineTransform(f.orbShape)
        orb.opacity = Float(f.orbOpacity)
        orb.setValue(f.orbHue, forKeyPath: "filters.hue.inputAngle")
        shadow.position = CGPoint(x: home.x + f.shadow.x, y: home.y + f.shadow.y)
        shadow.transform = CATransform3DMakeScale(f.shadowScale.width, f.shadowScale.height, 1)
        shadow.opacity = Float(f.shadowOpacity)
        halo.position = orb.position
        halo.transform = CATransform3DMakeScale(f.haloScale, f.haloScale, 1)
        halo.opacity = Float(f.halo)
        tile.opacity = f.tileInWindow ? 0 : 1
        tile.position = CGPoint(x: f.tileCenter.x + drift.x * f.tileFollow, y: f.tileCenter.y + drift.y * f.tileFollow)
        var tt = CATransform3DMakeRotation(f.tileRotation, 0, 0, 1)
        tt = CATransform3DScale(tt, f.tileShape.width, f.tileShape.height, 1)
        tile.transform = tt
        let dy = dockOffset(f)
        // Everything below the lip is hidden once the squircle is in the air (it only gets there over the bin).
        var keep = container.bounds
        if let clip = f.tileClip { keep = CGRect(x: 0, y: clip.maxY + dy, width: keep.width, height: keep.height - clip.maxY - dy) }
        if keep != holderRect {
            holderRect = keep
            tileHolder.frame = keep
            tileHolder.bounds = keep          // sublayers keep screen-local coordinates
        }
        let base = choreography.geo.trash.iconRect
        for l in [drawnTrash, trashLayer] {
            l.position = CGPoint(x: base.midX, y: base.minY + dy)
            l.transform = CATransform3DMakeScale(f.trashGulp.width, f.trashGulp.height, 1)
        }
        trashLayer.opacity = Float(f.trashFull)
        if f.lipRing >= 0 {
            let p = f.lipRing
            let e = CGFloat(HeroChoreography.easeOut(Double(p)))
            ring.position = CGPoint(x: choreography.geo.trash.mouth.x, y: choreography.geo.trash.mouth.y + dy)
            ring.transform = CATransform3DMakeScale(1 + 0.75 * e, 1 + 0.75 * e, 1)
            ring.opacity = Float(f.lipRingStrength * (1 - p) * (1 - p))
        } else {
            ring.opacity = 0
        }
        CATransaction.commit()
        if let dockView, let fakeDock {
            // The glass's first render is expensive: draw it once, practically invisible, before it's needed.
            if warmFrames < 3 {
                warmFrames += 1
                dockView.alphaValue = 0.01
                dockView.frame.origin.y = fakeDock.frame.minY
            } else {
                dockView.alphaValue = 1
                dockView.frame.origin.y = fakeDock.frame.minY + dy
            }
        }
        hero.applyIcon(f)
    }

    private func dockOffset(_ f: HeroFrame) -> CGFloat {
        guard let fakeDock else { return 0 }
        return -(1 - f.dockReveal) * (fakeDock.frame.maxY + 12)
    }

    private func finish(at t: Double) {
        guard !finishing else { return }
        finishing = true
        apply(choreography.sample(choreography.duration), t: choreography.duration)
        if !helloSent { helloSent = true; hero?.sayHello() }
        hero?.runnerDidFinish(at: t, choreography: choreography)   // the window takes over the hover, same phase
        link?.invalidate()
        link = nil
        // Give the window a couple of frames to show its orb before the panel's copy goes away.
        Task { @MainActor [panel] in
            try? await Task.sleep(for: .milliseconds(60))
            panel.orderOut(nil)
        }
    }

    /// Window moved to another display mid-flight: drop the flight and settle into the final state.
    private func abort() {
        link?.invalidate(); link = nil
        panel.orderOut(nil)
        if !helloSent { helloSent = true; hero?.sayHello() }
        hero?.runnerDidFinish(at: choreography.duration, choreography: choreography)
    }

    /// Window closed or view removed: tear down immediately.
    func cancel() {
        link?.invalidate(); link = nil
        panel.orderOut(nil)
        hero?.runnerDidFinish(at: choreography.duration, choreography: nil)
    }
}

// MARK: - Trash locator

/// Where the Dock's Trash is on `screen` (screen-local, y up), or nil when it isn't visibly there (Dock hidden,
/// auto-hidden, on another display, or a full-screen Space). Uses Accessibility when trusted, else estimates from
/// the Dock's preferences.
enum TrashLocator {
    @MainActor
    static func trash(on screen: NSScreen, useAccessibility: Bool = true) -> TrashTarget? {
        // A full-screen Space hides the Dock without changing any preference or the screen's visibleFrame (and AX
        // still reports the Trash where it would be), so first check the Dock is really drawn on this display.
        guard dockIsShowing(on: screen) else { return nil }
        let o = screen.frame.origin
        if useAccessibility, AXIsProcessTrusted(), let t = viaAccessibility(screen: screen) { return t.offsetBy(dx: -o.x, dy: -o.y) }
        return estimate(on: screen)?.offsetBy(dx: -o.x, dy: -o.y)
    }

    /// True when the Dock has an on-screen window at the Dock level on `screen` (window list; no permission needed).
    @MainActor
    static func dockIsShowing(on screen: NSScreen) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return true }    // can't tell: don't block the Trash
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == dock.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == dockLevel,
                  let b = w[kCGWindowBounds as String] as! CFDictionary?,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            let flipped = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            if flipped.intersects(screen.frame) { return true }
        }
        return false
    }

    @MainActor
    private static func viaAccessibility(screen: NSScreen) -> TrashTarget? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute),
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            // AX is top-left origin on the primary display.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
        }
        for list in children(app) {
            guard let listFrame = frame(list), listFrame.width > 0 else { continue }
            for item in children(list) where (attr(item, kAXSubroleAttribute) as? String) == "AXTrashDockItem" {
                guard let f = frame(item), screen.frame.contains(CGPoint(x: f.midX, y: f.midY)) else { return nil }
                let bottomDock = listFrame.width > listFrame.height
                // Item frames are tile + 4 wide and include the running-indicator strip; measured on macOS 27 the
                // icon's centre is 1 pt above the item's centre.
                let tile = bottomDock ? f.width - 4 : f.height - 4
                let c = CGPoint(x: f.midX, y: f.midY + (bottomDock ? 1 : 0))
                return TrashTarget(iconRect: CGRect(x: c.x - tile / 2, y: c.y - tile / 2, width: tile, height: tile), isDrawn: false)
            }
        }
        return nil
    }

    @MainActor
    private static func estimate(on screen: NSScreen) -> TrashTarget? {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dock?.string(forKey: "orientation") ?? "bottom"
        let dockHeight = screen.visibleFrame.minY - screen.frame.minY
        guard orientation == "bottom", dock?.bool(forKey: "autohide") != true, dockHeight > 20 else { return nil }
        let persistentApps = dock?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let persistentOthers = dock?.array(forKey: "persistent-others") as? [[String: Any]] ?? []
        let pinned = Set(persistentApps.compactMap { (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) })
        let runningUnpinned = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !pinned.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != "com.apple.finder"
        }.count
        let showRecents = (dock?.object(forKey: "show-recents") as? Bool) ?? true
        let recents = showRecents ? min((dock?.array(forKey: "recent-apps") ?? []).count, 3) : 0
        let tileSetting = CGFloat(dock?.double(forKey: "tilesize") ?? 0)
        let tile = tileSetting > 0 ? tileSetting : max(32, dockHeight - 26)
        // Measured against the Dock's own item frames (macOS 27): items are tile + 4 pt apart, a separator is about
        // half a tile, and the items are centred on the screen.
        let pitch = tile + 4
        let apps = CGFloat(persistentApps.count + 1 /* Finder */ + runningUnpinned + recents)
        let others = CGFloat(persistentOthers.count + 1 /* Trash */)
        let separators: CGFloat = 1 + (recents > 0 ? 1 : 0)
        let width = (apps + others) * pitch + separators * tile * 0.48
        guard width < screen.frame.width else { return nil }
        let x = screen.frame.midX + width / 2 - pitch / 2
        let y = screen.frame.minY + dockHeight / 2 + 3
        return TrashTarget(iconRect: CGRect(x: x - tile / 2, y: y - tile / 2, width: tile, height: tile), isDrawn: false)
    }
}

// MARK: - Drawn Dock (when the real one isn't showing)

/// A small macOS-style Dock — a few of the system's own app icons, a separator and the Trash — that slides up from
/// the bottom of the window's screen when the real Dock (and its Trash) can't be used.
@MainActor
struct FakeDock {
    var frame: CGRect          // screen-local, fully revealed
    var icons: [(URL, CGRect)] // app icons, dock-local
    var separatorX: CGFloat    // dock-local
    var tile: CGFloat
    var trash: TrashTarget     // screen-local

    static let appPaths = ["/System/Library/CoreServices/Finder.app", "/System/Applications/Apps.app",
                           "/Applications/Safari.app", "/System/Applications/Messages.app",
                           "/System/Applications/Mail.app", "/System/Applications/Music.app",
                           "/System/Applications/System Settings.app"]

    static func layout(on screen: NSScreen) -> FakeDock {
        let pref = CGFloat(UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 0)
        let tile = pref > 0 ? min(64, max(42, pref)) : 52
        let pad: CGFloat = 9, gap: CGFloat = 6
        let urls = appPaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        var x = pad
        var icons: [(URL, CGRect)] = []
        for u in urls {
            icons.append((u, CGRect(x: x, y: pad, width: tile, height: tile)))
            x += tile + gap
        }
        let separatorX = x + 2
        x += 10
        let trashLocal = CGRect(x: x, y: pad, width: tile, height: tile)
        x += tile + pad
        let size = CGSize(width: x, height: tile + 2 * pad)
        let frame = CGRect(x: (screen.frame.width - size.width) / 2, y: 6, width: size.width, height: size.height)
        let trash = TrashTarget(iconRect: trashLocal.offsetBy(dx: frame.minX, dy: frame.minY), isDrawn: true)
        return FakeDock(frame: frame, icons: icons, separatorX: separatorX, tile: tile, trash: trash)
    }

    func makeView(scale: CGFloat) -> NSView {
        let iconsView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        iconsView.wantsLayer = true
        for (url, rect) in icons {
            let l = CALayer()
            l.frame = rect
            l.contentsScale = scale
            l.contentsGravity = .resizeAspect
            let image = NSWorkspace.shared.icon(forFile: url.path)
            var r = CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale))
            l.contents = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
            iconsView.layer?.addSublayer(l)
        }
        let sep = CALayer()
        sep.frame = CGRect(x: separatorX, y: frame.height * 0.2, width: 1, height: frame.height * 0.6)
        sep.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        iconsView.layer?.addSublayer(sep)
        let radius = min(frame.height / 2, 24)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = radius
            glass.contentView = iconsView
            return glass
        } else {
            let v = NSVisualEffectView(frame: frame)
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = radius
            v.layer?.masksToBounds = true
            v.addSubview(iconsView)
            return v
        }
    }
}
