import AppKit
import QuartzCore
import WispCore

/// One display's drawing surface with its own display link. Converts the global companion position to local
/// coordinates and draws the companion (Metal) plus its decorations when it is on this display.
final class OverlayView: NSView {
    fileprivate let screenOrigin: CGPoint
    private let companion = CompanionMetalLayer()
    private let decorations = CompanionDecorations()
    private let fallback = FallbackArrowLayer()
    private var wasVisible = false
    private let inkUnder = CAShapeLayer()
    private let inkTop = CAShapeLayer()
    private let ringUnder = CAShapeLayer()
    private let ringTop = CAShapeLayer()
    private let labelPill = CALayer()
    private let labelText = CATextLayer()
    private var link: CADisplayLink?
    private var idleRate = false
    /// Called every frame of this display's link with its target timestamp.
    var onFrame: ((CFTimeInterval) -> Void)?
    /// Configured companion size; the Metal surface is sized for it once (flight scaling is a transform).
    var canvasScale: Double = 1 { didSet { resizeSurface() } }

    init(frame: NSRect, screen: NSScreen) {
        screenOrigin = screen.frame.origin
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        companion.contentsScale = screen.backingScaleFactor
        companion.anchorPoint = CGPoint(x: CompanionShapes.hotspot.x, y: 1 - CompanionShapes.hotspot.y)
        companion.opacity = 0
        decorations.contentsScale = screen.backingScaleFactor
        decorations.opacity = 0
        fallback.opacity = 0
        for (shape, width) in [(inkUnder, 8.0), (inkTop, 4.5), (ringUnder, 6.0), (ringTop, 3.0)] {
            shape.fillColor = nil
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = screen.backingScaleFactor
            layer?.addSublayer(shape)
        }
        inkUnder.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        ringUnder.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        inkUnder.shadowColor = NSColor.black.cgColor
        inkUnder.shadowOpacity = 0.25
        inkUnder.shadowRadius = 3
        inkUnder.shadowOffset = CGSize(width: 0, height: -1)
        labelPill.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        labelPill.cornerRadius = 11
        labelPill.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        labelPill.borderWidth = 1
        labelPill.opacity = 0
        labelPill.anchorPoint = CGPoint(x: 0, y: 0.5)
        labelText.contentsScale = screen.backingScaleFactor
        labelText.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        labelText.fontSize = 13
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.alignmentMode = .center
        labelText.truncationMode = .end
        labelPill.addSublayer(labelText)
        layer?.addSublayer(fallback)
        layer?.addSublayer(companion)
        layer?.addSublayer(labelPill)
        layer?.addSublayer(decorations)
        setAccessibilityElement(false)
        resizeSurface()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            companion.contentsScale = scale
            decorations.contentsScale = scale
            resizeSurface()
        }
    }

    /// Fixed drawable for the configured size (with headroom for the landing overshoot). Never resized per frame.
    private func resizeSurface() {
        let side = OverlayController.baseCanvas * CGFloat(canvasScale) * 1.1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        companion.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        companion.updateDrawableSize()
        CATransaction.commit()
    }

    // MARK: Display link

    func startDisplayLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(linkFired(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        idleRate = false
    }

    func stopDisplayLink() {
        link?.invalidate()
        link = nil
    }

    func setIdleFrameRate(_ idle: Bool) {
        guard idle != idleRate, let link else { return }
        idleRate = idle
        link.preferredFrameRateRange = idle ? CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20) : .default
    }

    @objc private func linkFired(_ link: CADisplayLink) {
        onFrame?(link.targetTimestamp)
    }

    // MARK: Drawing

    func render(_ frame: CompanionFrame) {
        renderDrawings(frame)
        let local = CGPoint(x: frame.position.x - screenOrigin.x, y: frame.position.y - screenOrigin.y)
        let side = OverlayController.baseCanvas * CGFloat(canvasScale)
        let visible = frame.opacity > 0.003 && bounds.insetBy(dx: -side * 2, dy: -side * 2).contains(local)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard visible else {
            if wasVisible {
                companion.opacity = 0
                decorations.opacity = 0
                fallback.opacity = 0
                wasVisible = false
            }
            return
        }
        wasVisible = true
        // Flight scale and tilt as a transform about the hotspot (the layer's anchor point).
        let flightScale = CGFloat(frame.scale) / 1.1
        var transform = CATransform3DMakeRotation(CGFloat(frame.tilt), 0, 0, 1)
        transform = CATransform3DScale(transform, flightScale, flightScale, 1)

        if CompanionRenderer.shared.isReady {
            fallback.opacity = 0
            companion.position = local
            companion.transform = transform
            companion.opacity = 1
            var uniforms = CompanionUniforms(time: frame.reduceMotion ? 0 : frame.time, morph: frame.morph,
                                             opacity: frame.opacity, glow: frame.glow, squash: frame.squash)
            uniforms.outline = frame.outline
            CompanionRenderer.shared.draw(into: companion, uniforms: uniforms, theme: frame.theme)
        } else {
            companion.opacity = 0
            fallback.position = local
            let s = CGFloat(canvasScale * frame.scale)
            fallback.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(frame.tilt)).scaledBy(x: s, y: s))
            fallback.opacity = Float(frame.opacity)
            fallback.tint(frame.theme)
        }

        // Decorations sit to the right of the companion, vertically centred on its body.
        let shown = side * CGFloat(frame.scale)
        decorations.position = CGPoint(x: local.x + shown * 0.58, y: local.y - shown * 0.42)
        decorations.update(mode: frame.mode, level: frame.level, time: frame.time, theme: frame.theme,
                           reduceMotion: frame.reduceMotion, scale: canvasScale * frame.scale)
        decorations.opacity = Float(frame.opacity)
    }
}

extension OverlayView {
    /// Ink strokes (traced by the companion) and highlight rings, in this display's coordinates.
    func renderDrawings(_ frame: CompanionFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let accent = NSColor(srgbRed: frame.theme.accent.r, green: frame.theme.accent.g, blue: frame.theme.accent.b, alpha: 1).cgColor
        inkTop.strokeColor = accent
        ringTop.strokeColor = accent
        let alpha = Float(frame.drawingAlpha)
        let ink = CGMutablePath()
        for stroke in frame.inks where stroke.count >= 2 {
            ink.move(to: local(stroke[0]))
            for p in stroke.dropFirst() { ink.addLine(to: local(p)) }
        }
        inkUnder.path = ink
        inkTop.path = ink
        let rings = CGMutablePath()
        var ringAlpha: Float = 0
        for ring in frame.rings {
            let c = local(ring.center)
            rings.addEllipse(in: CGRect(x: c.x - ring.radius, y: c.y - ring.radius, width: ring.radius * 2, height: ring.radius * 2))
            ringAlpha = max(ringAlpha, Float(ring.alpha))
        }
        ringUnder.path = rings
        ringTop.path = rings
        inkUnder.opacity = alpha
        inkTop.opacity = alpha
        ringUnder.opacity = alpha * ringAlpha
        ringTop.opacity = alpha * ringAlpha

        // Label pill beside the newest ring ("Export"), popping in like a small speech bubble.
        if let ring = frame.rings.last, !ring.label.isEmpty, ring.labelScale > 0 {
            let text = String(ring.label.prefix(28))
            let width = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width) + 22
            let c = local(ring.center)
            labelPill.bounds = CGRect(x: 0, y: 0, width: width, height: 22)
            // Above the ring, so it doesn't cover the element's own text (the arrow body sits lower right).
            labelPill.anchorPoint = CGPoint(x: 0.5, y: 0)
            labelPill.position = CGPoint(x: c.x, y: c.y + ring.radius + 6)
            labelText.string = text
            labelText.frame = CGRect(x: 6, y: 3, width: width - 12, height: 17)
            labelPill.transform = CATransform3DMakeScale(CGFloat(ring.labelScale), CGFloat(ring.labelScale), 1)
            labelPill.opacity = alpha
        } else {
            labelPill.opacity = 0
        }
    }

    private func local(_ p: Vec2) -> CGPoint { CGPoint(x: p.x - screenOrigin.x, y: p.y - screenOrigin.y) }
}

/// Level meter (listening) and thinking dots, drawn beside the companion.
final class CompanionDecorations: CALayer {
    private var bars: [CALayer] = []
    private var smoothed: [Float] = Array(repeating: 0, count: 5)

    override init() {
        super.init()
        bounds = CGRect(x: 0, y: 0, width: 40, height: 24)
        anchorPoint = CGPoint(x: 0, y: 0.5)
        // One soft shadow for the whole group (cheaper than a shadow per bar).
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.45
        shadowRadius = 2
        shadowOffset = CGSize(width: 0, height: -0.5)
        for _ in 0..<5 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            addSublayer(bar)
            bars.append(bar)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(mode: CompanionMode, level: Float, time: CFTimeInterval, theme: CompanionTheme, reduceMotion: Bool, scale: Double) {
        setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        let accent = NSColor(srgbRed: theme.accent.r, green: theme.accent.g, blue: theme.accent.b, alpha: 1).cgColor
        switch mode {
        case .listening:
            isHidden = false
            // Centre-weighted bars driven by the voice; a flat line honestly means "no sound".
            let weights: [Float] = [0.55, 0.85, 1.0, 0.8, 0.6]
            for (i, bar) in bars.enumerated() {
                bar.opacity = 1
                let wobble: Float = reduceMotion ? 1 : Float(0.8 + 0.2 * sin(time * 9 + Double(i) * 1.3))
                let target = min(1, pow(level, 0.7) * weights[i] * wobble * 1.25)
                smoothed[i] = AudioMath.smooth(previous: smoothed[i], next: target, attack: 0.5, release: 0.18)
                let h = 3 + CGFloat(smoothed[i]) * 17
                bar.frame = CGRect(x: CGFloat(i) * 6, y: 12 - h / 2, width: 3, height: h)
                bar.cornerRadius = 1.5
                bar.backgroundColor = NSColor.white.cgColor
            }
            shadowColor = accent
        case .thinking:
            isHidden = false
            for (i, bar) in bars.enumerated() {
                guard i < 3 else { bar.opacity = 0; continue }
                bar.opacity = 1
                let phase = reduceMotion ? 0.5 : max(0, sin(time * 5 - Double(i) * 0.9))
                let s = 4 + CGFloat(phase) * 2
                bar.frame = CGRect(x: CGFloat(i) * 8, y: 12 - s / 2, width: s, height: s)
                bar.cornerRadius = s / 2
                bar.backgroundColor = NSColor.white.cgColor
            }
            shadowColor = accent
        case .resting, .hidden:
            isHidden = true
        }
    }
}

/// Vector arrow used only if Metal is unavailable.
final class FallbackArrowLayer: CAShapeLayer {
    override init() {
        super.init()
        let side = OverlayController.baseCanvas
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        anchorPoint = CGPoint(x: CompanionShapes.hotspot.x, y: 1 - CompanionShapes.hotspot.y)
        var flip = CGAffineTransform(translationX: 0, y: side).scaledBy(x: side, y: -side)
        path = CompanionShapes.arrow().fill.copy(using: &flip)
        strokeColor = NSColor.white.cgColor
        lineWidth = 1.5
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.35
        shadowRadius = 3
        shadowOffset = CGSize(width: 1, height: -2)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func tint(_ theme: CompanionTheme) {
        fillColor = NSColor(srgbRed: theme.accent.r, green: theme.accent.g, blue: theme.accent.b, alpha: 1).cgColor
    }
}
