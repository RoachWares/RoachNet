import AppKit
import SwiftUI

public struct RoachBackgroundInks: Sendable {
    public var primary: Color
    public var secondary: Color
    public var tertiary: Color
    public var info: Color

    public init(primary: Color, secondary: Color, tertiary: Color, info: Color) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.info = info
    }

    public init(accentsOf theme: RoachResolvedTheme) {
        self.init(
            primary: theme[.accent], secondary: theme[.accentSecondary], tertiary: theme[.accentTertiary],
            info: theme[.accentInfo])
    }

    public init(backgroundOf theme: RoachResolvedTheme) {
        let colors = theme.background.colors.map(\.color)
        func pick(_ index: Int) -> Color { colors.isEmpty ? theme[.accent] : colors[index % colors.count] }
        self.init(primary: pick(0), secondary: pick(1), tertiary: pick(2), info: pick(3))
    }
}

public struct RoachBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        RoachThemeBackdrop(theme: RoachThemeRuntime.shared.theme, reduceMotion: reduceMotion)
    }
}

public struct RoachThemeBackdrop: View {
    public let theme: RoachResolvedTheme
    public let reduceMotion: Bool
    public let frameRate: Double
    public let isPreview: Bool
    public let fieldState: RoachFieldParameters.State

    public init(
        theme: RoachResolvedTheme,
        reduceMotion: Bool = false,
        frameRate: Double = 24,
        isPreview: Bool = false,
        fieldState: RoachFieldParameters.State = .reading
    ) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        self.frameRate = frameRate
        self.isPreview = isPreview
        self.fieldState = fieldState
    }

    public var body: some View {
        if theme.background.style == .field {
            RoachFieldBackdrop(
                theme: theme,
                reduceMotion: reduceMotion,
                isPreview: isPreview,
                composition: isPreview ? .preview : .app,
                state: isPreview ? .hero : fieldState
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        } else {
            classicBackdrop
        }
    }

    @ViewBuilder
    private var classicBackdrop: some View {
        let spec = theme.background
        let animates = spec.style.animates && spec.motion && !reduceMotion
        let renderer = RoachBackdropRenderer(
            style: spec.style,
            inks: RoachBackgroundInks(backgroundOf: theme),
            ink: theme[.ink],
            gain: spec.intensity,
            isDark: theme.isDark,
            rise: spec.rise
        )
        let speed = spec.speed

        ZStack {
            baseGradient

            if spec.style == .image, let url = spec.imageURL, let image = RoachBackdropImageCache.image(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: spec.imageBlur)
                    .overlay(theme[.shade].opacity(spec.imageDim))
                    .clipped()
            }

            if spec.style != .solid && spec.style != .image && spec.intensity > 0 {
                if animates {
                    TimelineView(.animation(minimumInterval: 1.0 / max(1, frameRate), paused: reduceMotion)) {
                        timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate * speed
                        Canvas { context, size in
                            renderer.draw(in: &context, size: size, time: time)
                        }
                    }
                    .blendMode(theme.glowBlendMode)
                } else {
                    Canvas { context, size in
                        renderer.draw(in: &context, size: size, time: 0)
                    }
                    .blendMode(theme.glowBlendMode)
                }
            }

            if spec.style == .scanlines {
                RoachScanlineOverlay(color: theme.isDark ? Color.black : theme[.ink], gain: spec.intensity)
            }

            vignette(spec.vignette)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var baseGradient: some View {
        let spec = theme.background
        if theme.isDark {
            LinearGradient(
                colors: [
                    theme[.shade],
                    spec.top.color,
                    spec.bottom.color.opacity(0.95),
                    theme[.shade].opacity(0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [spec.top.color, spec.bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder
    private func vignette(_ amount: Double) -> some View {
        if amount > 0 {
            let scale = amount / 0.48
            let shade = theme[.shade]
            ZStack {
                LinearGradient(
                    colors: [
                        shade.opacity(0), shade.opacity(min(1, 0.18 * scale)), shade.opacity(min(1, 0.40 * scale)),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [Color.clear, shade.opacity(min(1, 0.18 * scale)), shade.opacity(min(1, 0.48 * scale))],
                    center: .center,
                    startRadius: 160,
                    endRadius: 820
                )
            }
        }
    }
}

enum RoachBackdropImageCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct RoachBackdropRenderer: Sendable {
    let style: RoachBackgroundStyle
    let inks: RoachBackgroundInks
    let ink: Color
    let gain: Double
    let isDark: Bool
    let rise: Bool

    func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        switch style {
        case .signal:
            drawDitherField(context: &context, size: size, time: time)
            drawPerspectiveBunkerGrid(context: &context, size: size, time: time)
            drawCircuitTraces(context: &context, size: size, time: time)
            drawRoachSigil(context: &context, size: size, time: time)
            drawSignalDither(context: &context, size: size, time: time)
            drawSignalPackets(context: &context, size: size, time: time)
        case .grid:
            scaled(0.45).drawDitherField(context: &context, size: size, time: time)
            scaled(1.7).drawPerspectiveBunkerGrid(context: &context, size: size, time: time)
        case .circuit:
            scaled(0.35).drawDitherField(context: &context, size: size, time: time)
            scaled(1.5).drawCircuitTraces(context: &context, size: size, time: time)
            drawCircuitTraces(
                context: &context, size: CGSize(width: size.width, height: size.height * 0.6), time: time + 40)
            scaled(1.2).drawSignalPackets(context: &context, size: size, time: time)
        case .aurora:
            drawAurora(context: &context, size: size, time: time)
        case .starfield:
            drawStarfield(context: &context, size: size, time: time)
        case .scanlines:
            scaled(0.35).drawDitherField(context: &context, size: size, time: time)
            drawScanlines(context: &context, size: size, time: time)
        case .particles:
            drawParticles(context: &context, size: size, time: time)
        case .paper:
            drawPaper(context: &context, size: size)
        case .field, .solid, .image:
            break
        }
    }

    private func scaled(_ factor: Double) -> RoachBackdropRenderer {
        RoachBackdropRenderer(style: style, inks: inks, ink: ink, gain: gain * factor, isDark: isDark, rise: rise)
    }

    func drawDitherField(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let cell: CGFloat = size.width < 900 ? 7 : 8
        let columns = max(1, Int(ceil(size.width / cell)))
        let rows = max(1, Int(ceil(size.height / cell)))
        let crawl = time * 0.044
        let shimmer = time * 0.86

        for row in 0...rows {
            for column in 0...columns {
                let nx = Double(column) / Double(columns)
                let ny = Double(row) / Double(rows)
                let centerFade = max(0, 1.0 - abs(nx - 0.55) * 0.84 - abs(ny - 0.46) * 0.92)
                let diagonalA = 0.5 + 0.5 * sin(((nx * 2.4) + (ny * 3.4) + crawl) * Double.pi * 2.0)
                let diagonalB = 0.5 + 0.5 * sin(((nx * -3.1) + (ny * 1.9) + time * 0.021) * Double.pi * 2.0)
                let crawlNoise = 0.5 + 0.5 * sin((ny * 48.0) + shimmer + sin(nx * 9.5 + time * 0.19))
                let lowerRack = max(0, 1.0 - abs((ny + (0.035 * sin(time * 0.18))) - 0.78) * 5.6)
                let leftSignal = max(0, 1.0 - abs((nx - ny * 0.30) - 0.08 - (0.05 * sin(time * 0.24))) * 8.6)
                let rightSignal = max(0, 1.0 - abs((nx + ny * 0.20) - 0.92 - (0.04 * cos(time * 0.20))) * 7.0)
                let intensity =
                    0.014
                    + (centerFade * 0.032)
                    + (diagonalA * diagonalB * 0.052)
                    + (crawlNoise * 0.016)
                    + (lowerRack * 0.086)
                    + (leftSignal * 0.064)
                    + (rightSignal * 0.036)
                let threshold = RoachDither.threshold(row: row, column: column) * 0.24

                guard intensity > threshold else { continue }

                let flicker = 0.68 + (0.32 * sin(shimmer + Double(row * 11 + column * 7)))
                let alpha = min(0.17, max(0.012, (intensity - threshold) * flicker))
                let rect = CGRect(
                    x: CGFloat(column) * cell,
                    y: CGFloat(row) * cell,
                    width: max(1, cell - 2),
                    height: max(1, cell - 2)
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.4),
                    with: .color(
                        RoachDither.cellColor(
                            row: row, column: column, accent: inks.primary, intensity: alpha * gain, inks: inks))
                )
            }
        }
    }

    func drawSignalDither(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let cell: CGFloat = size.width < 900 ? 5 : 6
        let columns = max(1, Int(ceil(size.width / cell)))
        let rows = max(1, Int(ceil(size.height / cell)))
        let sweepA = 0.5 + 0.42 * sin(time * 0.31)
        let sweepB = 0.58 + 0.30 * cos(time * 0.23)

        for row in 0...rows {
            for column in 0...columns {
                let nx = Double(column) / Double(columns)
                let ny = Double(row) / Double(rows)
                let beamA = max(0, 1.0 - abs((nx * 0.78 + ny * 0.22) - sweepA) * 34.0)
                let beamB = max(0, 1.0 - abs((nx * -0.18 + ny * 0.96) - sweepB) * 28.0)
                let pulse = 0.5 + 0.5 * sin(time * 5.2 + Double(column * 3 - row * 5))
                let threshold = 0.52 + RoachDither.threshold(row: row, column: column) * 0.32
                let intensity = (beamA * 0.36) + (beamB * 0.24) + (pulse * 0.025)

                guard intensity > threshold else { continue }

                let rect = CGRect(
                    x: CGFloat(column) * cell,
                    y: CGFloat(row) * cell,
                    width: max(1, cell - 2),
                    height: max(1, cell - 2)
                )
                let accent: Color = (row + column) % 7 == 0 ? inks.info : inks.primary
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.8),
                    with: .color(accent.opacity(gain * min(0.24, max(0.04, intensity - threshold + 0.05))))
                )
            }
        }
    }

    func drawPerspectiveBunkerGrid(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let horizon = size.height * (0.58 + (0.018 * sin(time * 0.11)))
        let vanishing = CGPoint(
            x: size.width * (0.55 + (0.025 * cos(time * 0.10))),
            y: horizon
        )
        let floorBottom = size.height + 72
        let spacing = max(54, size.width / 12)

        for index in -8...8 {
            let bottomX = (size.width * 0.5) + (CGFloat(index) * spacing)
            let accent: Color = index.isMultiple(of: 3) ? inks.info : inks.primary
            drawDitherLine(
                context: &context,
                from: CGPoint(x: bottomX, y: floorBottom),
                to: vanishing,
                cell: 7,
                color: accent,
                intensity: 0.030,
                time: time,
                phase: Double(index) * 0.47
            )
        }

        for index in 1...15 {
            let depth = CGFloat(index) / 15
            let eased = pow(depth, 1.85)
            let y = horizon + eased * (size.height - horizon + 78)
            let left = CGPoint(
                x: vanishing.x + (-size.width * 0.66 - vanishing.x) * depth,
                y: y
            )
            let right = CGPoint(
                x: vanishing.x + (size.width * 1.18 - vanishing.x) * depth,
                y: y
            )
            let accent: Color = index.isMultiple(of: 4) ? inks.tertiary : inks.primary
            drawDitherLine(
                context: &context,
                from: left,
                to: right,
                cell: index.isMultiple(of: 5) ? 6 : 8,
                color: accent,
                intensity: index.isMultiple(of: 5) ? 0.044 : 0.026,
                time: time,
                phase: Double(index) * 0.33
            )
        }

        for index in 0..<6 {
            let t = CGFloat(index) / 5
            let y = size.height * (0.12 + (t * 0.38))
            let inset = size.width * (0.04 + (t * 0.11))
            let leftTop = CGPoint(x: inset, y: y)
            let leftBottom = CGPoint(x: max(0, vanishing.x - size.width * (0.44 - t * 0.15)), y: horizon + 18 + t * 44)
            let rightTop = CGPoint(x: size.width - inset, y: y + 8)
            let rightBottom = CGPoint(
                x: min(size.width, vanishing.x + size.width * (0.42 - t * 0.13)), y: horizon + 22 + t * 40)

            drawDitherLine(
                context: &context,
                from: leftTop,
                to: leftBottom,
                cell: 9,
                color: t > 0.5 ? inks.secondary : inks.primary,
                intensity: 0.020,
                time: time,
                phase: Double(index) * 0.41
            )
            drawDitherLine(
                context: &context,
                from: rightTop,
                to: rightBottom,
                cell: 9,
                color: t > 0.5 ? inks.info : inks.primary,
                intensity: 0.020,
                time: time,
                phase: Double(index) * 0.59
            )
        }
    }

    func drawCircuitTraces(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let leftOrigins: [CGFloat] = [0.18, 0.31, 0.47, 0.69]
        for (index, yRatio) in leftOrigins.enumerated() {
            let y = size.height * (yRatio + (0.010 * sin(time * 0.18 + Double(index))))
            let points = [
                CGPoint(x: -24, y: y),
                CGPoint(x: size.width * (0.16 + CGFloat(index) * 0.025), y: y),
                CGPoint(
                    x: size.width * (0.16 + CGFloat(index) * 0.025), y: y + CGFloat(index.isMultiple(of: 2) ? 42 : -38)),
                CGPoint(
                    x: size.width * (0.30 + CGFloat(index) * 0.032), y: y + CGFloat(index.isMultiple(of: 2) ? 42 : -38)),
            ]
            drawTrace(
                points, context: &context, cell: 6, color: index.isMultiple(of: 2) ? inks.primary : inks.info,
                intensity: 0.052, time: time, phase: Double(index) * 0.8)
            drawDitherNode(
                context: &context, center: points.last ?? .zero, radius: 13, color: inks.primary, intensity: 0.08,
                time: time, phase: Double(index))
        }

        let rightOrigins: [CGFloat] = [0.24, 0.39, 0.56, 0.73]
        for (index, yRatio) in rightOrigins.enumerated() {
            let y = size.height * (yRatio + (0.012 * cos(time * 0.16 + Double(index))))
            let points = [
                CGPoint(x: size.width + 24, y: y),
                CGPoint(x: size.width * (0.86 - CGFloat(index) * 0.018), y: y),
                CGPoint(
                    x: size.width * (0.86 - CGFloat(index) * 0.018), y: y + CGFloat(index.isMultiple(of: 2) ? -48 : 36)),
                CGPoint(
                    x: size.width * (0.70 - CGFloat(index) * 0.026), y: y + CGFloat(index.isMultiple(of: 2) ? -48 : 36)),
            ]
            drawTrace(
                points, context: &context, cell: 6, color: index.isMultiple(of: 2) ? inks.secondary : inks.tertiary,
                intensity: 0.040, time: time, phase: Double(index) * 1.2)
            drawDitherNode(
                context: &context, center: points.last ?? .zero, radius: 11,
                color: index.isMultiple(of: 2) ? inks.secondary : inks.tertiary, intensity: 0.06, time: time,
                phase: Double(index) + 2)
        }
    }

    func drawRoachSigil(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let scale = min(max(min(size.width, size.height) * 0.19, 112), 230)
        let center = CGPoint(
            x: size.width * (size.width < 820 ? 0.78 : 0.84),
            y: size.height * (0.74 + (0.012 * sin(time * 0.12)))
        )
        let cell: CGFloat = 6
        let width = scale * 0.72
        let height = scale
        let cols = max(1, Int(width / cell))
        let rows = max(1, Int(height / cell))

        for row in 0...rows {
            for column in 0...cols {
                let localX = (CGFloat(column) / CGFloat(cols) - 0.5) * 2
                let localY = (CGFloat(row) / CGFloat(rows) - 0.5) * 2
                let abdomen = pow(localX / 0.46, 2) + pow((localY - 0.18) / 0.78, 2)
                let thorax = pow(localX / 0.38, 2) + pow((localY + 0.26) / 0.42, 2)
                let head = pow(localX / 0.30, 2) + pow((localY + 0.72) / 0.25, 2)
                let shellLine =
                    max(0, 1.0 - abs(abs(Double(localX)) - 0.20) * 15) * max(0, 1 - abs(Double(localY)) * 0.72)
                let body = abdomen < 1 || thorax < 1 || head < 1
                let outline = abs(abdomen - 1) < 0.11 || abs(thorax - 1) < 0.13 || abs(head - 1) < 0.15
                let threshold = RoachDither.threshold(row: row, column: column)
                let pulse = 0.5 + 0.5 * sin(time * 1.3 + Double(row + column) * 0.38)
                let intensity = (outline ? 0.13 : 0) + (body ? 0.033 : 0) + (shellLine * 0.085) + (pulse * 0.010)

                guard intensity > threshold * 0.30 else { continue }

                let rect = CGRect(
                    x: center.x - width / 2 + CGFloat(column) * cell,
                    y: center.y - height / 2 + CGFloat(row) * cell,
                    width: max(1, cell - 2),
                    height: max(1, cell - 2)
                )
                let color = outline ? inks.primary : inks.info
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(color.opacity(gain * min(0.18, intensity * 0.70)))
                )
            }
        }

        for side: CGFloat in [-1, 1] {
            for index in 0..<3 {
                let y = center.y - scale * (0.18 - CGFloat(index) * 0.22)
                let start = CGPoint(x: center.x + side * scale * 0.18, y: y)
                let mid = CGPoint(
                    x: center.x + side * scale * (0.42 + CGFloat(index) * 0.05), y: y + CGFloat(index - 1) * 16)
                let end = CGPoint(
                    x: center.x + side * scale * (0.58 + CGFloat(index) * 0.06), y: y + CGFloat(index - 1) * 31)
                drawDitherLine(
                    context: &context, from: start, to: mid, cell: 6, color: inks.primary, intensity: 0.070, time: time,
                    phase: Double(index) + Double(side))
                drawDitherLine(
                    context: &context, from: mid, to: end, cell: 6, color: inks.primary, intensity: 0.060, time: time,
                    phase: Double(index) + 2.0)
            }

            let antennaBase = CGPoint(x: center.x + side * scale * 0.13, y: center.y - scale * 0.46)
            let antennaTip = CGPoint(x: center.x + side * scale * 0.46, y: center.y - scale * 0.72)
            drawDitherLine(
                context: &context, from: antennaBase, to: antennaTip, cell: 5, color: inks.tertiary, intensity: 0.058,
                time: time, phase: Double(side) + 3.0)
        }
    }

    func drawSignalPackets(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        for index in 0..<18 {
            let lane = Double(index % 6) / 5.0
            let progress = (time * (0.035 + Double(index % 4) * 0.006) + Double(index) * 0.137)
                .truncatingRemainder(dividingBy: 1)
            let x = size.width * CGFloat(0.08 + (progress * 0.84))
            let yBase = size.height * CGFloat(0.22 + lane * 0.54)
            let y = yBase + CGFloat(sin(time * 0.42 + Double(index) * 1.7)) * 22
            let color: Color

            switch index % 4 {
            case 0:
                color = inks.primary
            case 1:
                color = inks.info
            case 2:
                color = inks.secondary
            default:
                color = inks.tertiary
            }

            drawDitherNode(
                context: &context,
                center: CGPoint(x: x, y: y),
                radius: CGFloat(7 + (index % 3) * 3),
                color: color,
                intensity: 0.070,
                time: time,
                phase: Double(index) * 0.9
            )

            let tail = CGPoint(x: x - CGFloat(34 + (index % 4) * 8), y: y + CGFloat((index % 3) - 1) * 8)
            drawDitherLine(
                context: &context, from: tail, to: CGPoint(x: x, y: y), cell: 5, color: color, intensity: 0.036,
                time: time, phase: Double(index) * 0.31)
        }
    }

    func drawTrace(
        _ points: [CGPoint], context: inout GraphicsContext, cell: CGFloat, color: Color, intensity: Double,
        time: TimeInterval, phase: Double
    ) {
        guard points.count >= 2 else { return }

        for index in 0..<(points.count - 1) {
            drawDitherLine(
                context: &context,
                from: points[index],
                to: points[index + 1],
                cell: cell,
                color: color,
                intensity: intensity,
                time: time,
                phase: phase + Double(index) * 0.37
            )
        }
    }

    func drawDitherLine(
        context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        cell: CGFloat,
        color: Color,
        intensity: Double,
        time: TimeInterval,
        phase: Double
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(1, hypot(dx, dy))
        let steps = max(1, Int(distance / max(3, cell * 0.86)))

        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = start.x + dx * t
            let y = start.y + dy * t
            let row = Int((y / cell).rounded(.down))
            let column = Int((x / cell).rounded(.down))
            let packet = 0.5 + 0.5 * sin(time * 1.2 + Double(step) * 0.22 + phase)
            let threshold = RoachDither.threshold(row: row, column: column) * 0.34
            let fade = 0.52 + 0.48 * Double(1 - abs(t - 0.5) * 1.3)
            let alpha = (intensity * fade) + (packet * 0.014)

            guard alpha > threshold else { continue }

            let rect = CGRect(
                x: x - cell / 2,
                y: y - cell / 2,
                width: max(1, cell - 2),
                height: max(1, cell - 2)
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .color(color.opacity(gain * min(0.20, max(0.018, alpha - threshold + 0.014))))
            )
        }
    }

    func drawDitherNode(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        color: Color,
        intensity: Double,
        time: TimeInterval,
        phase: Double
    ) {
        let cell: CGFloat = 5
        let steps = max(2, Int((radius * 2) / cell))

        for row in -steps...steps {
            for column in -steps...steps {
                let x = CGFloat(column) * cell
                let y = CGFloat(row) * cell
                let distance = hypot(x, y)
                guard distance <= radius else { continue }

                let gridRow = Int(((center.y + y) / cell).rounded(.down))
                let gridColumn = Int(((center.x + x) / cell).rounded(.down))
                let ring = max(0, 1.0 - abs(Double(distance / max(1, radius)) - 0.72) * 4.0)
                let core = max(0, 1.0 - Double(distance / max(1, radius)))
                let pulse = 0.5 + 0.5 * sin(time * 2.3 + phase)
                let alpha = intensity * (ring * 0.75 + core * 0.55 + pulse * 0.12)
                let threshold = RoachDither.threshold(row: gridRow, column: gridColumn) * 0.30

                guard alpha > threshold else { continue }

                let rect = CGRect(
                    x: center.x + x - cell / 2,
                    y: center.y + y - cell / 2,
                    width: max(1, cell - 1.7),
                    height: max(1, cell - 1.7)
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.2),
                    with: .color(color.opacity(gain * min(0.18, alpha - threshold + 0.018)))
                )
            }
        }
    }

    private func hash(_ n: Double, _ salt: Double) -> Double {
        let value = sin(n * 12.9898 + salt * 78.233) * 43758.5453
        return value - floor(value)
    }

    func drawAurora(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let colors = [inks.primary, inks.secondary, inks.info, inks.tertiary, inks.primary]
        let base = (isDark ? 0.17 : 0.13) * gain
        let span = max(size.width, size.height)

        for (index, color) in colors.enumerated() {
            let i = Double(index)
            let cx = size.width * CGFloat(0.5 + 0.40 * sin(time * (0.021 + i * 0.004) + i * 1.7))
            let cy = size.height * CGFloat(0.36 + 0.26 * cos(time * (0.017 + i * 0.003) + i * 2.3))
            let radius = span * CGFloat(0.32 + 0.08 * sin(time * 0.05 + i))
            let breathe = 0.72 + 0.28 * sin(time * 0.11 + i * 1.3)
            let rect = CGRect(x: cx - radius, y: cy - radius * 0.62, width: radius * 2, height: radius * 1.24)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(min(1, base * breathe)), color.opacity(0)]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        for index in 0..<3 {
            let i = Double(index)
            let baseY = size.height * CGFloat(0.20 + i * 0.13)
            let amplitude = size.height * 0.05
            var path = Path()
            let steps = 56
            for step in 0...steps {
                let x = size.width * CGFloat(step) / CGFloat(steps)
                let wave =
                    sin(Double(step) * 0.19 + time * (0.08 + i * 0.02) + i * 2.1)
                    + 0.4 * sin(Double(step) * 0.07 - time * 0.05 + i)
                let point = CGPoint(x: x, y: baseY + amplitude * CGFloat(wave))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let thickness = size.height * CGFloat(0.06 + i * 0.015)
            let shimmer = 0.7 + 0.3 * sin(time * 0.23 + i * 1.9)
            for layer in 1...5 {
                let fraction = CGFloat(layer) / 5
                let alpha = min(1, 0.028 * gain * shimmer)
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            .clear, colors[index].opacity(alpha), colors[index + 1].opacity(alpha * 0.8), .clear,
                        ]),
                        startPoint: CGPoint(x: 0, y: baseY),
                        endPoint: CGPoint(x: size.width, y: baseY)
                    ),
                    style: StrokeStyle(lineWidth: thickness * fraction, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    func drawStarfield(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = Double(size.width)
        let height = Double(size.height)
        let span = max(size.width, size.height)

        for (index, color) in [inks.secondary, inks.info].enumerated() {
            let i = Double(index)
            let center = CGPoint(
                x: size.width * CGFloat(0.28 + 0.44 * i + 0.04 * sin(time * 0.01 + i)),
                y: size.height * CGFloat(0.30 + 0.35 * i)
            )
            let radius = span * 0.45
            context.fill(
                Path(
                    ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                ),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(min(1, 0.07 * gain)), color.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        let count = Int(min(280, max(90, width * height / 6500)))
        for index in 0..<count {
            let seed = Double(index)
            let layer = index % 3
            let depth = 0.35 + Double(layer) * 0.32
            var x = (hash(seed, 1) * width - time * 5.5 * depth).truncatingRemainder(dividingBy: width)
            if x < 0 { x += width }
            let y = hash(seed, 2) * height + sin(time * 0.05 + seed) * 5 * depth
            let twinkle = 0.55 + 0.45 * sin(time * (0.7 + hash(seed, 3) * 2.4) + seed * 3.1)
            let radius = CGFloat(0.5 + 0.3 * depth + depth * 1.2 * hash(seed, 4))
            let color: Color
            if index % 11 == 0 {
                color = inks.primary
            } else if index % 13 == 0 {
                color = inks.info
            } else if index % 17 == 0 {
                color = inks.secondary
            } else {
                color = ink
            }
            let alpha = min(1, (0.10 + 0.34 * depth) * twinkle * gain)
            let point = CGPoint(x: x, y: y)
            context.fill(
                Path(
                    ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(alpha))
            )
            if layer == 2, index % 5 == 0 {
                let halo = radius * 5
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(alpha * 0.28), color.opacity(0)]),
                        center: point,
                        startRadius: 0,
                        endRadius: halo
                    )
                )
            }
        }
    }

    func drawScanlines(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let full = Path(CGRect(origin: .zero, size: size))
        let span = max(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        context.fill(
            full,
            with: .radialGradient(
                Gradient(colors: [inks.primary.opacity(min(1, 0.11 * gain)), inks.primary.opacity(0)]),
                center: center,
                startRadius: 0,
                endRadius: span * 0.72
            )
        )

        let bandHeight = size.height * 0.16
        let travel = Double(size.height + bandHeight)
        let offset = CGFloat((time * 38).truncatingRemainder(dividingBy: travel)) - bandHeight
        let band = CGRect(x: 0, y: offset, width: size.width, height: bandHeight)
        context.fill(
            Path(band),
            with: .linearGradient(
                Gradient(colors: [.clear, inks.primary.opacity(min(1, 0.07 * gain)), .clear]),
                startPoint: CGPoint(x: 0, y: band.minY),
                endPoint: CGPoint(x: 0, y: band.maxY)
            )
        )

        let flicker = 0.5 + 0.5 * sin(time * 9.7) * sin(time * 3.1)
        context.fill(full, with: .color(inks.primary.opacity(min(1, 0.014 * gain * flicker))))
    }

    func drawParticles(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = Double(size.width)
        let height = Double(size.height)
        let travel = height + 60
        let palette = [inks.primary, inks.tertiary, inks.secondary, inks.primary, inks.info]
        let count = Int(min(150, max(50, width * height / 13000)))

        for index in 0..<count {
            let seed = Double(index)
            let speed = 12 + hash(seed, 1) * 30
            var progress = (hash(seed, 2) * travel + time * speed).truncatingRemainder(dividingBy: travel)
            if progress < 0 { progress += travel }
            let y = rise ? height + 30 - progress : progress - 30
            let sway = sin(time * (0.35 + hash(seed, 3)) + seed) * (8 + hash(seed, 4) * 20)
            let x = hash(seed, 5) * width + sway
            let fade = sin((progress / travel) * Double.pi)
            let flicker = rise ? 0.62 + 0.38 * sin(time * (2.6 + hash(seed, 6) * 4.5) + seed) : 1
            let radius = CGFloat(0.9 + hash(seed, 7) * 2.3)
            let color = palette[index % palette.count]
            let alpha = min(1, 0.46 * fade * flicker * gain)
            guard alpha > 0.004 else { continue }

            let point = CGPoint(x: x, y: y)
            context.fill(
                Path(
                    ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(alpha))
            )
            let halo = radius * 4.5
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(alpha * 0.32), color.opacity(0)]),
                    center: point,
                    startRadius: 0,
                    endRadius: halo
                )
            )
        }
    }

    func drawPaper(context: inout GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let height = Double(size.height)
        let span = max(size.width, size.height)

        for index in 0..<4 {
            let seed = Double(index) + 0.5
            let center = CGPoint(x: hash(seed, 21) * width, y: hash(seed, 22) * height)
            let radius = span * CGFloat(0.25 + hash(seed, 23) * 0.3)
            context.fill(
                Path(
                    ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                ),
                with: .radialGradient(
                    Gradient(colors: [ink.opacity(min(1, 0.03 * gain)), ink.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        let specks = Int(min(9000, width * height / 240))
        var grain = Path()
        for index in 0..<specks {
            let seed = Double(index)
            grain.addRect(CGRect(x: hash(seed, 11) * width, y: hash(seed, 13) * height, width: 1, height: 1))
        }
        context.fill(grain, with: .color(ink.opacity(min(1, 0.055 * gain))))

        var fibers = Path()
        for index in 0..<140 {
            let seed = Double(index) + 0.25
            let start = CGPoint(x: hash(seed, 31) * width, y: hash(seed, 32) * height)
            let angle = hash(seed, 33) * Double.pi * 2
            let length = 6 + hash(seed, 34) * 16
            fibers.move(to: start)
            fibers.addLine(
                to: CGPoint(x: start.x + CGFloat(cos(angle) * length), y: start.y + CGFloat(sin(angle) * length)))
        }
        context.stroke(fibers, with: .color(ink.opacity(min(1, 0.05 * gain))), lineWidth: 0.6)
    }
}

struct RoachScanlineOverlay: View {
    let color: Color
    let gain: Double

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var y: CGFloat = 0
            while y < size.height {
                lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            context.fill(lines, with: .color(color.opacity(min(1, 0.16 * gain))))
        }
        .allowsHitTesting(false)
    }
}
