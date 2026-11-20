import AppKit
@preconcurrency import Metal
import QuartzCore
import os
import WispCore

/// Per-frame drawing parameters for the companion.
public struct CompanionUniforms {
    public var time: Double = 0
    /// 0 = arrow, 1 = pointing hand (values in between morph smoothly).
    public var morph: Double = 0
    public var opacity: Double = 1
    /// Emphasis glow (listening, pointing), 0...1.
    public var glow: Double = 0
    /// Brief squash on landing or press, 0...1.
    public var squash: Double = 0
    /// Debug: render the raw fluid value as greyscale.
    public var debugValue = false
    /// Outline around the silhouette.
    public var outline: CompanionOutline = .white
    public init(time: Double = 0, morph: Double = 0, opacity: Double = 1, glow: Double = 0, squash: Double = 0) {
        self.time = time; self.morph = morph; self.opacity = opacity; self.glow = glow; self.squash = squash
    }
}

/// Shared Metal resources: device, pipeline (compiled once from source), SDF textures for both shapes.
public final class CompanionRenderer: @unchecked Sendable {
    public static let shared = CompanionRenderer()

    let device: MTLDevice?
    private let state = OSAllocatedUnfairLock<Built?>(initialState: nil)
    private let queue: MTLCommandQueue?

    /// Everything built off the main thread at launch: pipeline (from source) and the two SDF textures.
    private struct Built: @unchecked Sendable {
        var pipeline: MTLRenderPipelineState
        var arrow: MTLTexture
        var hand: MTLTexture
        var sampler: MTLSamplerState
    }

    /// True once the shader compiled and textures exist; until then callers draw a simple vector fallback.
    public var isReady: Bool { state.withLock { $0 != nil } }

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        guard device != nil else {
            Log.overlay.error("no Metal device; companion uses fallback drawing")
            return
        }
        // Compiling MSL and building the SDFs takes ~100 ms: never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in build() }
    }

    private func build() {
        guard let device else { return }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let library = try device.makeLibrary(source: companionShaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "companion_vertex")
            desc.fragmentFunction = library.makeFunction(name: "companion_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: desc)
            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerDesc.sAddressMode = .clampToEdge
            samplerDesc.tAddressMode = .clampToEdge
            let arrowShape = CompanionShapes.arrow()
            let handShape = CompanionShapes.hand()
            guard let sampler = device.makeSamplerState(descriptor: samplerDesc),
                  let arrow = Self.texture(device: device, data: ShapeSDF.make(fill: arrowShape.fill, details: arrowShape.details)),
                  let hand = Self.texture(device: device, data: ShapeSDF.make(fill: handShape.fill, details: handShape.details)) else {
                Log.overlay.error("companion resources could not be created")
                return
            }
            let built = Built(pipeline: pipeline, arrow: arrow, hand: hand, sampler: sampler)
            state.withLock { $0 = built }
            Log.overlay.info("companion renderer ready in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000), privacy: .public) ms")
        } catch {
            Log.overlay.error("companion shader failed to compile: \(String(describing: error), privacy: .public)")
        }
    }

    /// Blocks until the renderer is ready (offscreen tools and tests only).
    public func waitUntilReady(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return isReady
    }

    private static func texture(device: MTLDevice, data: [Float], size n: Int = 320) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: n, height: n, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let halves = data.map { Float16($0) }
        halves.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: n * 4)
        }
        return texture
    }

    /// Packs theme + per-frame values into the shader's `float4 u[16]` layout.
    static func packUniforms(_ u: CompanionUniforms, theme: CompanionTheme) -> [SIMD4<Float>] {
        var out = themeUniforms(theme)
        out[0] = SIMD4(Float(u.time), Float(u.morph), Float(u.opacity), u.debugValue ? 1 : 0)
        out[2].w = Float(u.glow)
        out[4].w = Float(u.squash)
        switch u.outline {
        case .white: out[14] = SIMD4(0.026, 1, 1, 1)
        case .black: out[14] = SIMD4(0.026, 0.02, 0.02, 0.03)
        case .none: out[14] = SIMD4(0, 0, 0, 0)
        }
        return out
    }

    private static let themeCache = OSAllocatedUnfairLock<[String: [SIMD4<Float>]]>(initialState: [:])

    /// The per-theme part of the uniforms, computed once per theme.
    static func themeUniforms(_ theme: CompanionTheme) -> [SIMD4<Float>] {
        if let cached = themeCache.withLock({ $0[theme.id] }) { return cached }
        let built = buildThemeUniforms(theme)
        themeCache.withLock { $0[theme.id] = built }
        return built
    }

    private static func buildThemeUniforms(_ theme: CompanionTheme) -> [SIMD4<Float>] {
        let u = CompanionUniforms()
        var out = [SIMD4<Float>](repeating: .zero, count: 16)
        let styleIndex: Float = theme.style == .bands ? 0 : (theme.style == .blobs ? 1 : 2)
        out[1] = SIMD4(Float(theme.scale), Float(theme.warp), Float(theme.softness), Float(theme.speed))
        // The shader indexes u[5 + i]; never let a palette run outside u[5...12].
        let stops = Array(theme.palette.prefix(8))
        let count = max(2, stops.count)
        out[2] = SIMD4(Float(theme.gloss), styleIndex, Float(count), Float(u.glow))
        // Extrusion down-right (canvas units, y down) and a softer, larger shadow offset.
        // A hint of depth only; the outline is the edge now.
        out[3] = SIMD4(0.0, 0.010, 0.020, 0.040)
        // Stable per-theme pattern offset (String.hashValue is randomized per launch).
        let seed = Float(theme.id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 }) * 0.013
        out[4] = SIMD4(0.030, 0.30, seed, Float(u.squash))
        for i in 0..<count {
            let c = stops.isEmpty ? RGB(0.5, 0.5, 0.5) : stops[min(i, stops.count - 1)]
            out[5 + i] = SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
        }
        out[13] = SIMD4(Float(theme.accent.r), Float(theme.accent.g), Float(theme.accent.b), 1)
        return out
    }

    /// Renders one frame offscreen (theme gallery thumbnails, tests, contact sheets).
    public func renderImage(pixels: Int, uniforms: CompanionUniforms, theme: CompanionTheme) -> CGImage? {
        guard let built = state.withLock({ $0 }), let device, let queue else { return nil }
        let pipeline = built.pipeline, sampler = built.sampler, arrowTexture = built.arrow, handTexture = built.hand
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var packed = Self.packUniforms(uniforms, theme: theme)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&packed, length: MemoryLayout<SIMD4<Float>>.stride * packed.count, index: 0)
        encoder.setFragmentTexture(arrowTexture, index: 0)
        encoder.setFragmentTexture(handTexture, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        target.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws one frame into `layer`. Returns false if nothing could be drawn (no drawable, not ready).
    @discardableResult
    func draw(into layer: CompanionMetalLayer, uniforms: CompanionUniforms, theme: CompanionTheme) -> Bool {
        guard let built = state.withLock({ $0 }), let queue, layer.drawableSize.width >= 1 else { return false }
        // Never block the main thread waiting for a drawable: skip this frame if two are already in flight.
        guard layer.reserveFrame() else { return false }
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else {
            layer.releaseFrame()
            return false
        }
        buffer.addCompletedHandler { [weak layer] _ in layer?.releaseFrame() }
        let pipeline = built.pipeline, sampler = built.sampler, arrowTexture = built.arrow, handTexture = built.hand
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            buffer.commit() // completes immediately and releases the reserved frame
            return false
        }
        var packed = Self.packUniforms(uniforms, theme: theme)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&packed, length: MemoryLayout<SIMD4<Float>>.stride * packed.count, index: 0)
        encoder.setFragmentTexture(arrowTexture, index: 0)
        encoder.setFragmentTexture(handTexture, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        return true
    }
}

/// A transparent Metal layer that draws the companion canvas.
final class CompanionMetalLayer: CAMetalLayer {
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    /// Claims a frame slot; false when two frames are already queued for this layer.
    func reserveFrame() -> Bool {
        inFlight.withLock { count in
            guard count < 2 else { return false }
            count += 1
            return true
        }
    }

    func releaseFrame() {
        inFlight.withLock { $0 = max(0, $0 - 1) }
    }

    override init() {
        super.init()
        device = CompanionRenderer.shared.device
        pixelFormat = .bgra8Unorm
        isOpaque = false
        framebufferOnly = true
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        presentsWithTransaction = false
        maximumDrawableCount = 3
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func updateDrawableSize() {
        let s = contentsScale
        drawableSize = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
    }
}
