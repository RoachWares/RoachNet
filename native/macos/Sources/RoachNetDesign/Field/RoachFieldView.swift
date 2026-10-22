import AppKit
import MetalKit
import QuartzCore
import SwiftUI
import simd

public final class RoachFieldEngine: @unchecked Sendable {
    public static let shared: RoachFieldEngine? = RoachFieldEngine()

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let blue: MTLTexture
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: RoachFieldShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: RoachFieldShader.vertexFunction)
            descriptor.fragmentFunction = library.makeFunction(name: RoachFieldShader.fragmentFunction)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("[RoachNet field] The field shader did not compile: \(error)")
            return nil
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: RoachBlueNoise.side,
            height: RoachBlueNoise.side,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        RoachBlueNoise.bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, RoachBlueNoise.side, RoachBlueNoise.side),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: RoachBlueNoise.side
            )
        }
        self.device = device
        self.queue = queue
        self.blue = texture
    }

    func encode(_ encoder: MTLRenderCommandEncoder, frame: RoachFieldFrame, a: [SIMD4<Float>], b: [SIMD4<Float>]) {
        let uniforms = frame.uniforms()
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        a.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        b.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.setFragmentTexture(blue, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    public func still(
        field: RoachJSON?,
        ground: RoachRGBA,
        size: CGSize,
        cell: CGFloat = 2,
        phase: Double? = nil,
        composition: RoachFieldParameters.Composition = .preview,
        state: RoachFieldParameters.State = .hero
    ) -> CGImage? {
        let cellSize = max(1, cell)
        let width = max(1, Int(ceil(size.width / cellSize)))
        let height = max(1, Int(ceil(size.height / cellSize)))
        guard width <= 4096, height <= 4096 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
            let commands = queue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: ground.red, green: ground.green, blue: ground.blue, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let block = RoachFieldParameters.pack(field, composition: composition, state: state)
        var frame = RoachFieldFrame()
        frame.fieldSize = SIMD2(Float(width), Float(height))
        frame.viewSize = SIMD2(Float(CGFloat(width) * cellSize), Float(CGFloat(height) * cellSize))
        frame.cell = Float(cellSize)
        frame.phase = Float(phase ?? (field?["still"]?.number ?? 12.5))
        frame.ground = SIMD4(Float(ground.red), Float(ground.green), Float(ground.blue), 1)
        encode(encoder, frame: frame, a: block, b: block)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for index in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(index, index + 2) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

struct RoachFieldFrame {
    var fieldSize = SIMD2<Float>(1, 1)
    var viewSize = SIMD2<Float>(1, 1)
    var cell: Float = 2
    var phase: Float = 0
    var detail: Float = 1
    var pointer = SIMD3<Float>(0, 0, 0)
    var sweep = SIMD4<Float>(0, 0, 0, 0)
    var ground = SIMD4<Float>(0, 0, 0, 1)

    func uniforms() -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: .zero, count: 25)
        slots[0] = SIMD4(fieldSize.x, fieldSize.y, 0, 0)
        slots[1] = SIMD4(viewSize.x, viewSize.y, cell, phase)
        slots[2] = SIMD4(0, 0, detail, 0)
        slots[3] = SIMD4(pointer.x, pointer.y, pointer.z, 0)
        slots[11] = sweep
        slots[24] = ground
        return slots
    }
}

final class RoachFieldNSView: MTKView, MTKViewDelegate {
    private let engine: RoachFieldEngine
    private var blockA: [SIMD4<Float>]
    private var blockB: [SIMD4<Float>]
    private var currentField: RoachJSON?
    private var currentGround = SIMD4<Float>(0, 0, 0, 1)
    private var targetGround = SIMD4<Float>(0, 0, 0, 1)
    private var composition = RoachFieldParameters.Composition.app
    private var fieldState = RoachFieldParameters.State.reading
    private var cellPoints: CGFloat = 2
    private var stillPhase: Double = 12.5
    private var phase: Double = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var wantsStill = false
    private var sweep: (start: CFTimeInterval, origin: CGPoint, duration: Double, band: Double, reach: Double)?
    private var pointer = SIMD3<Double>(0, 0, 0)
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(engine: RoachFieldEngine) {
        self.engine = engine
        self.blockA = RoachFieldParameters.pack(nil)
        self.blockB = blockA
        super.init(frame: .zero, device: engine.device)
        colorPixelFormat = RoachFieldEngine.pixelFormat
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = 30
        delegate = self
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.isOpaque = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    func configure(
        field: RoachJSON?,
        ground: RoachRGBA,
        composition: RoachFieldParameters.Composition,
        state: RoachFieldParameters.State,
        reduceMotion: Bool
    ) {
        let groundVector = SIMD4(Float(ground.red), Float(ground.green), Float(ground.blue), 1)
        let cell = CGFloat(min(6, max(1, field?["cell"]?.number ?? 2)))
        let changed =
            field != currentField || composition != self.composition || state != fieldState
            || groundVector != targetGround
        stillPhase = field?["still"]?.number ?? 12.5
        wantsStill = reduceMotion
        if changed {
            let block = RoachFieldParameters.pack(field, composition: composition, state: state)
            let animate =
                currentField != nil && field != currentField && !holdsStill
                && window?.occlusionState.contains(.visible) == true
            if animate {
                blockB = block
                let origin =
                    pointer.z > 0.5 ? CGPoint(x: pointer.x, y: pointer.y) : CGPoint(x: bounds.width * 0.5, y: 0)
                let reach = Double(
                    hypot(max(origin.x, bounds.width - origin.x), max(origin.y, bounds.height - origin.y)))
                sweep = (CACurrentMediaTime(), origin, 0.95, 160, reach)
                targetGround = groundVector
            } else {
                blockA = block
                blockB = block
                sweep = nil
                currentGround = groundVector
                targetGround = groundVector
            }
            currentField = field
            self.composition = composition
            self.fieldState = state
        }
        if cell != cellPoints {
            cellPoints = cell
            updateDrawableSize()
        }
        applyRunState()
        if isPaused { needsDisplay = true }
    }

    private var holdsStill: Bool {
        wantsStill || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func applyRunState() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let paused = holdsStill || !visible
        if paused != isPaused {
            isPaused = paused
            enableSetNeedsDisplay = paused
        }
        preferredFramesPerSecond = NSApp?.isActive == false ? 12 : 30
        if paused { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.applyRunState() }
            })
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyRunState() }
                })
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateDrawableSize()
        applyRunState()
    }

    @objc private func accessibilityOptionsChanged() { applyRunState() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private var snappedCell: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        let devicePixels = max(1, (cellPoints * scale).rounded())
        return devicePixels / scale
    }

    private func updateDrawableSize() {
        let cell = snappedCell
        let width = max(1, Int(ceil(bounds.width / cell)))
        let height = max(1, Int(ceil(bounds.height / cell)))
        let size = CGSize(width: width, height: height)
        if drawableSize != size { drawableSize = size }
        if isPaused { needsDisplay = true }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let rawStep = lastTimestamp > 0 ? now - lastTimestamp : 1.0 / 30.0
        let step = rawStep > 0 && rawStep < 0.1 ? rawStep : 1.0 / 30.0
        lastTimestamp = now
        let still = holdsStill

        if let window, !still {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let inside = bounds.contains(location) && NSApp.isActive && window.isKeyWindow
            let target = SIMD3(Double(location.x), Double(bounds.height - location.y), inside ? 1 : 0)
            let ease = 1 - pow(0.0015, step)
            pointer += (target - pointer) * ease
        } else {
            pointer.z = 0
        }

        if !still { phase += step * composition.motion * fieldState.motion }
        if phase > 7200 { phase -= 7200 }

        var frame = RoachFieldFrame()
        frame.fieldSize = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        let cell = snappedCell
        frame.viewSize = SIMD2(Float(drawableSize.width * cell), Float(drawableSize.height * cell))
        frame.cell = Float(cell)
        frame.phase = Float(still ? stillPhase : phase)
        frame.pointer = SIMD3(Float(pointer.x), Float(pointer.y), Float(still ? 0 : pointer.z))

        if let active = sweep {
            let progress = min(1, max(0, (now - active.start) / active.duration))
            if progress >= 1 || still {
                blockA = blockB
                currentGround = targetGround
                sweep = nil
            } else {
                let eased = 1 - pow(1 - progress, 4)
                frame.sweep = SIMD4(
                    Float(active.origin.x), Float(active.origin.y), Float(eased * (active.reach + active.band)),
                    Float(active.band))
                currentGround = simd_mix(currentGround, targetGround, SIMD4(repeating: Float(eased)))
            }
        }
        frame.ground = currentGround

        guard let pass = currentRenderPassDescriptor,
            let drawable = currentDrawable,
            let commands = engine.queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        engine.encode(encoder, frame: frame, a: blockA, b: sweep == nil ? blockA : blockB)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

struct RoachFieldRepresentable: NSViewRepresentable {
    let engine: RoachFieldEngine
    let field: RoachJSON?
    let ground: RoachRGBA
    let composition: RoachFieldParameters.Composition
    let state: RoachFieldParameters.State
    let reduceMotion: Bool

    func makeNSView(context: Context) -> RoachFieldNSView {
        let view = RoachFieldNSView(engine: engine)
        view.configure(field: field, ground: ground, composition: composition, state: state, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: RoachFieldNSView, context: Context) {
        view.configure(field: field, ground: ground, composition: composition, state: state, reduceMotion: reduceMotion)
    }
}

public struct RoachFieldBackdrop: View {
    public let theme: RoachResolvedTheme
    public let reduceMotion: Bool
    public let isPreview: Bool
    public let composition: RoachFieldParameters.Composition
    public let state: RoachFieldParameters.State

    public init(
        theme: RoachResolvedTheme,
        reduceMotion: Bool = false,
        isPreview: Bool = false,
        composition: RoachFieldParameters.Composition = .app,
        state: RoachFieldParameters.State = .reading
    ) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        self.isPreview = isPreview
        self.composition = composition
        self.state = state
    }

    public var body: some View {
        let ground = theme.rgba(.background).composited(over: theme.isDark ? .black : .white)
        if let engine = RoachFieldEngine.shared {
            if isPreview {
                RoachFieldStill(engine: engine, theme: theme, ground: ground)
            } else {
                RoachFieldRepresentable(
                    engine: engine,
                    field: theme.background.field,
                    ground: ground,
                    composition: composition,
                    state: state,
                    reduceMotion: reduceMotion || !theme.background.motion
                )
            }
        } else {
            ground.color
        }
    }
}

struct RoachFieldStill: View {
    let engine: RoachFieldEngine
    let theme: RoachResolvedTheme
    let ground: RoachRGBA

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: max(8, proxy.size.width.rounded()), height: max(8, proxy.size.height.rounded()))
            if let image = RoachFieldStillCache.image(engine: engine, theme: theme, ground: ground, size: size) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                ground.color
            }
        }
    }
}

enum RoachFieldStillCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, CGImageBox>()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func image(engine: RoachFieldEngine, theme: RoachResolvedTheme, ground: RoachRGBA, size: CGSize) -> CGImage?
    {
        let key = "\(theme.id)|\(theme.revision)|\(theme.isDark)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let cell = CGFloat(min(6, max(1, theme.background.field?["cell"]?.number ?? 2)))
        guard let image = engine.still(field: theme.background.field, ground: ground, size: size, cell: cell) else {
            return nil
        }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }
}
