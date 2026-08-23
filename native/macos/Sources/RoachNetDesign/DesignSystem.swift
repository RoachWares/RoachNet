import AppKit
import SwiftUI

public enum RoachPalette {
    public static let green = Color(red: 0.24, green: 0.98, blue: 0.54)
    public static let magenta = Color(red: 0.5686, green: 0.2196, blue: 0.8471)
    public static let bronze = Color(red: 0.98, green: 0.74, blue: 0.20)
    public static let cyan = Color(red: 0.40, green: 0.84, blue: 1.0)
    public static let background = Color(red: 0.010, green: 0.012, blue: 0.015)
    public static let backgroundRaised = Color(red: 0.026, green: 0.029, blue: 0.034)
    public static let panel = Color(red: 0.043, green: 0.047, blue: 0.055)
    public static let panelRaised = Color(red: 0.068, green: 0.073, blue: 0.084)
    public static let panelSoft = Color(red: 0.104, green: 0.110, blue: 0.126)
    public static let panelGlass = Color.white.opacity(0.045)
    public static let panelSpecular = Color.white.opacity(0.08)
    public static let border = Color.white.opacity(0.085)
    public static let borderStrong = Color.white.opacity(0.14)
    public static let text = Color.white.opacity(0.97)
    public static let muted = Color.white.opacity(0.68)
    public static let success = Color(red: 0.24, green: 0.98, blue: 0.54)
    public static let warning = Color(red: 0.93, green: 0.73, blue: 0.26)
    public static let shadow = Color.black.opacity(0.24)
}

fileprivate enum RoachDither {
    static let bayer4: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ]

    static func threshold(row: Int, column: Int) -> Double {
        bayer4[((row & 3) * 4) + (column & 3)] / 16.0
    }

    static func cellColor(row: Int, column: Int, accent: Color, intensity: Double) -> Color {
        let alpha = min(0.18, max(0.018, intensity))

        switch abs((row * 3 + column * 5) % 9) {
        case 0:
            return RoachPalette.magenta.opacity(alpha * 0.64)
        case 1, 5:
            return RoachPalette.cyan.opacity(alpha * 0.72)
        case 2:
            return accent.opacity(alpha * 0.92)
        default:
            return RoachPalette.green.opacity(alpha)
        }
    }
}

public struct RoachBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        RoachPalette.background,
                        RoachPalette.backgroundRaised.opacity(0.95),
                        Color.black.opacity(0.98),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Canvas { context, size in
                    Self.drawDitherField(context: &context, size: size, time: time)
                    Self.drawPerspectiveBunkerGrid(context: &context, size: size, time: time)
                    Self.drawCircuitTraces(context: &context, size: size, time: time)
                    Self.drawRoachSigil(context: &context, size: size, time: time)
                    Self.drawSignalDither(context: &context, size: size, time: time)
                    Self.drawSignalPackets(context: &context, size: size, time: time)
                }
                .blendMode(.screen)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.40),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.48),
                    ],
                    center: .center,
                    startRadius: 160,
                    endRadius: 820
                )
            }
            .ignoresSafeArea()
        }
    }

    private static func drawDitherField(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
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
                let intensity = 0.014
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
                    with: .color(RoachDither.cellColor(row: row, column: column, accent: RoachPalette.green, intensity: alpha))
                )
            }
        }
    }

    private static func drawSignalDither(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
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
                let accent: Color = (row + column) % 7 == 0 ? RoachPalette.cyan : RoachPalette.green
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.8),
                    with: .color(accent.opacity(min(0.24, max(0.04, intensity - threshold + 0.05))))
                )
            }
        }
    }

    private static func drawPerspectiveBunkerGrid(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
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
            let accent: Color = index.isMultiple(of: 3) ? RoachPalette.cyan : RoachPalette.green
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
            let accent: Color = index.isMultiple(of: 4) ? RoachPalette.bronze : RoachPalette.green
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
            let rightBottom = CGPoint(x: min(size.width, vanishing.x + size.width * (0.42 - t * 0.13)), y: horizon + 22 + t * 40)

            drawDitherLine(
                context: &context,
                from: leftTop,
                to: leftBottom,
                cell: 9,
                color: t > 0.5 ? RoachPalette.magenta : RoachPalette.green,
                intensity: 0.020,
                time: time,
                phase: Double(index) * 0.41
            )
            drawDitherLine(
                context: &context,
                from: rightTop,
                to: rightBottom,
                cell: 9,
                color: t > 0.5 ? RoachPalette.cyan : RoachPalette.green,
                intensity: 0.020,
                time: time,
                phase: Double(index) * 0.59
            )
        }
    }

    private static func drawCircuitTraces(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }

        let leftOrigins: [CGFloat] = [0.18, 0.31, 0.47, 0.69]
        for (index, yRatio) in leftOrigins.enumerated() {
            let y = size.height * (yRatio + (0.010 * sin(time * 0.18 + Double(index))))
            let points = [
                CGPoint(x: -24, y: y),
                CGPoint(x: size.width * (0.16 + CGFloat(index) * 0.025), y: y),
                CGPoint(x: size.width * (0.16 + CGFloat(index) * 0.025), y: y + CGFloat(index.isMultiple(of: 2) ? 42 : -38)),
                CGPoint(x: size.width * (0.30 + CGFloat(index) * 0.032), y: y + CGFloat(index.isMultiple(of: 2) ? 42 : -38)),
            ]
            drawTrace(points, context: &context, cell: 6, color: index.isMultiple(of: 2) ? RoachPalette.green : RoachPalette.cyan, intensity: 0.052, time: time, phase: Double(index) * 0.8)
            drawDitherNode(context: &context, center: points.last ?? .zero, radius: 13, color: RoachPalette.green, intensity: 0.08, time: time, phase: Double(index))
        }

        let rightOrigins: [CGFloat] = [0.24, 0.39, 0.56, 0.73]
        for (index, yRatio) in rightOrigins.enumerated() {
            let y = size.height * (yRatio + (0.012 * cos(time * 0.16 + Double(index))))
            let points = [
                CGPoint(x: size.width + 24, y: y),
                CGPoint(x: size.width * (0.86 - CGFloat(index) * 0.018), y: y),
                CGPoint(x: size.width * (0.86 - CGFloat(index) * 0.018), y: y + CGFloat(index.isMultiple(of: 2) ? -48 : 36)),
                CGPoint(x: size.width * (0.70 - CGFloat(index) * 0.026), y: y + CGFloat(index.isMultiple(of: 2) ? -48 : 36)),
            ]
            drawTrace(points, context: &context, cell: 6, color: index.isMultiple(of: 2) ? RoachPalette.magenta : RoachPalette.bronze, intensity: 0.040, time: time, phase: Double(index) * 1.2)
            drawDitherNode(context: &context, center: points.last ?? .zero, radius: 11, color: index.isMultiple(of: 2) ? RoachPalette.magenta : RoachPalette.bronze, intensity: 0.06, time: time, phase: Double(index) + 2)
        }
    }

    private static func drawRoachSigil(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
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
                let shellLine = max(0, 1.0 - abs(abs(Double(localX)) - 0.20) * 15) * max(0, 1 - abs(Double(localY)) * 0.72)
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
                let color = outline ? RoachPalette.green : RoachPalette.cyan
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(color.opacity(min(0.18, intensity * 0.70)))
                )
            }
        }

        for side: CGFloat in [-1, 1] {
            for index in 0..<3 {
                let y = center.y - scale * (0.18 - CGFloat(index) * 0.22)
                let start = CGPoint(x: center.x + side * scale * 0.18, y: y)
                let mid = CGPoint(x: center.x + side * scale * (0.42 + CGFloat(index) * 0.05), y: y + CGFloat(index - 1) * 16)
                let end = CGPoint(x: center.x + side * scale * (0.58 + CGFloat(index) * 0.06), y: y + CGFloat(index - 1) * 31)
                drawDitherLine(context: &context, from: start, to: mid, cell: 6, color: RoachPalette.green, intensity: 0.070, time: time, phase: Double(index) + Double(side))
                drawDitherLine(context: &context, from: mid, to: end, cell: 6, color: RoachPalette.green, intensity: 0.060, time: time, phase: Double(index) + 2.0)
            }

            let antennaBase = CGPoint(x: center.x + side * scale * 0.13, y: center.y - scale * 0.46)
            let antennaTip = CGPoint(x: center.x + side * scale * 0.46, y: center.y - scale * 0.72)
            drawDitherLine(context: &context, from: antennaBase, to: antennaTip, cell: 5, color: RoachPalette.bronze, intensity: 0.058, time: time, phase: Double(side) + 3.0)
        }
    }

    private static func drawSignalPackets(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
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
                color = RoachPalette.green
            case 1:
                color = RoachPalette.cyan
            case 2:
                color = RoachPalette.magenta
            default:
                color = RoachPalette.bronze
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
            drawDitherLine(context: &context, from: tail, to: CGPoint(x: x, y: y), cell: 5, color: color, intensity: 0.036, time: time, phase: Double(index) * 0.31)
        }
    }

    private static func drawTrace(_ points: [CGPoint], context: inout GraphicsContext, cell: CGFloat, color: Color, intensity: Double, time: TimeInterval, phase: Double) {
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

    private static func drawDitherLine(
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
                with: .color(color.opacity(min(0.20, max(0.018, alpha - threshold + 0.014))))
            )
        }
    }

    private static func drawDitherNode(
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
                    with: .color(color.opacity(min(0.18, alpha - threshold + 0.018)))
                )
            }
        }
    }
}

private struct RoachAnimatedChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cornerRadius: CGFloat
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 16.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                let rounded = Path(roundedRect: rect, cornerRadius: cornerRadius)

                context.stroke(
                    rounded,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.08),
                            accent.opacity(0.18),
                            RoachPalette.borderStrong,
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    ),
                    lineWidth: 1
                )

                let cell: CGFloat = 5
                let columns = max(1, Int(ceil(size.width / cell)))
                let rows = max(1, Int(ceil(size.height / cell)))
                let pulse = 0.5 + 0.5 * sin(time * 0.9)

                for row in 0...rows {
                    for column in 0...columns {
                        let x = CGFloat(column) * cell
                        let y = CGFloat(row) * cell
                        let distanceToEdge = min(min(x, y), min(max(0, size.width - x), max(0, size.height - y)))
                        let edge = max(0, 1 - Double(distanceToEdge / 76))
                        let drift = 0.5 + 0.5 * sin((Double(column) * 0.18) + (Double(row) * 0.11) + (time * 0.7))
                        let threshold = RoachDither.threshold(row: row, column: column) * 0.42
                        let intensity = (edge * 0.11) + (drift * 0.030) + (pulse * 0.012)

                        guard intensity > threshold else { continue }

                        let fill = RoachDither.cellColor(
                            row: row,
                            column: column,
                            accent: accent,
                            intensity: min(0.14, intensity - threshold + 0.018)
                        )
                        let cellRect = CGRect(x: x, y: y, width: max(1, cell - 2), height: max(1, cell - 2))
                        context.fill(Path(roundedRect: cellRect, cornerRadius: 1), with: .color(fill))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}

public struct RoachPanel<Content: View>: View {
    private let content: Content
    private let radius: CGFloat = 16

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .allowsHitTesting(false)
            )
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panel.opacity(0.94),
                                RoachPalette.panelRaised.opacity(0.90),
                                Color.black.opacity(0.28),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.clear,
                                Color.white.opacity(0.012),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color.white.opacity(0.022), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoachAnimatedChrome(cornerRadius: radius, accent: RoachPalette.green)
            )
            .shadow(color: RoachPalette.shadow.opacity(0.48), radius: 22, x: 0, y: 12)
            .shadow(color: RoachPalette.green.opacity(0.03), radius: 28, x: 0, y: 14)
    }
}

public struct RoachSpotlightPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent: Color
    private let content: Content
    private let radius: CGFloat = 18

    public init(accent: Color = RoachPalette.magenta, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.96),
                                    RoachPalette.panel.opacity(0.90),
                                    Color.black.opacity(0.34),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.10),
                                    RoachPalette.green.opacity(0.035),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 18.0, paused: reduceMotion)) { timeline in
                        Canvas { context, size in
                            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                            let cell: CGFloat = size.width < 620 ? 6 : 7
                            let columns = max(1, Int(ceil(size.width / cell)))
                            let rows = max(1, Int(ceil(size.height / cell)))

                            for row in 0...rows {
                                for column in 0...columns {
                                    let nx = Double(column) / Double(columns)
                                    let ny = Double(row) / Double(rows)
                                    let topEdge = max(0, 1.0 - ny * 4.4)
                                    let leftEdge = max(0, 1.0 - nx * 3.7)
                                    let crawl = 0.5 + 0.5 * sin((nx * 8.2) + (ny * 12.0) + time * 0.9)
                                    let threshold = RoachDither.threshold(row: row, column: column) * 0.52
                                    let intensity = (topEdge * 0.18) + (leftEdge * 0.08) + (crawl * 0.035)

                                    guard intensity > threshold else { continue }

                                    let rect = CGRect(
                                        x: CGFloat(column) * cell,
                                        y: CGFloat(row) * cell,
                                        width: max(1, cell - 2),
                                        height: max(1, cell - 2)
                                    )
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: 1.1),
                                        with: .color(RoachDither.cellColor(row: row, column: column, accent: accent, intensity: min(0.16, intensity - threshold + 0.025)))
                                    )
                                }
                            }
                        }
                        .blendMode(.screen)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.26),
                                Color.white.opacity(0.07),
                                RoachPalette.green.opacity(0.14),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoachAnimatedChrome(cornerRadius: radius, accent: accent)
            )
            .shadow(color: accent.opacity(0.07), radius: 18, x: 0, y: 10)
    }
}

public struct RoachKicker: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        RoachPalette.muted,
                        RoachPalette.text.opacity(0.76),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

public struct RoachPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachPrimaryButtonBody(configuration: configuration)
    }
}

public struct RoachSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachSecondaryButtonBody(configuration: configuration)
    }
}

public struct RoachUtilityButtonStyle: ButtonStyle {
    private let tint: Color

    public init(tint: Color = RoachPalette.green) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        RoachUtilityButtonBody(configuration: configuration, tint: tint)
    }
}

public struct RoachCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RoachCardButtonBody(configuration: configuration)
    }
}

private struct RoachPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.magenta.opacity(configuration.isPressed ? 0.84 : (hovered ? 0.94 : 0.88)),
                                    RoachPalette.green.opacity(configuration.isPressed ? 0.50 : (hovered ? 0.64 : 0.56)),
                                    RoachPalette.panelSoft.opacity(configuration.isPressed ? 0.86 : (hovered ? 0.92 : 0.88)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    RoachPalette.green.opacity(hovered ? 0.88 : 0.74),
                                    RoachPalette.magenta.opacity(hovered ? 0.58 : 0.46),
                                    Color.white.opacity(hovered ? 0.24 : 0.16),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.0
                        )

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(hovered ? 0.22 : 0.14),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                }
            )
            .shadow(color: RoachPalette.magenta.opacity(configuration.isPressed ? 0.10 : (hovered ? 0.20 : 0.13)), radius: hovered ? 18 : 10, x: 0, y: hovered ? 9 : 5)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: hovered)
    }
}

private struct RoachSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(RoachPalette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(configuration.isPressed ? 0.72 : (hovered ? 0.84 : 0.76)),
                                    RoachPalette.panel.opacity(configuration.isPressed ? 0.68 : (hovered ? 0.76 : 0.70)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(hovered ? RoachPalette.green.opacity(0.20) : RoachPalette.border, lineWidth: 1)
            )
            .shadow(color: hovered ? RoachPalette.green.opacity(0.07) : .clear, radius: hovered ? 9 : 0, x: 0, y: hovered ? 5 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: hovered)
    }
}

private struct RoachUtilityButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(hovered ? RoachPalette.text : tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 2)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(configuration.isPressed ? 0.76 : (hovered ? 0.88 : 0.78)),
                                    RoachPalette.panel.opacity(configuration.isPressed ? 0.72 : (hovered ? 0.82 : 0.72)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(hovered ? 0.14 : 0.08),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(hovered ? tint.opacity(0.24) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: tint.opacity(hovered ? 0.10 : 0.04), radius: hovered ? 12 : 8, x: 0, y: hovered ? 7 : 4)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.01 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -1 : 0))
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hovered)
    }
}

private struct RoachCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.02 : 1.0))
            .offset(y: configuration.isPressed ? 1 : (hovered ? -2 : 0))
            .shadow(
                color: RoachPalette.green.opacity(configuration.isPressed ? 0.05 : (hovered ? 0.12 : 0.05)),
                radius: hovered ? 20 : 12,
                x: 0,
                y: hovered ? 14 : 8
            )
            .onHover { inside in
                hovered = inside
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hovered)
    }
}

public struct RoachStageStrip: View {
    private let titles: [String]
    private let activeIndex: Int

    public init(titles: [String], activeIndex: Int) {
        self.titles = titles
        self.activeIndex = activeIndex
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Text(String(index + 1))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(index <= activeIndex ? RoachPalette.text : RoachPalette.muted)

                    if index == activeIndex {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                .fill(index == activeIndex ? RoachPalette.panelSoft.opacity(0.76) : RoachPalette.panelRaised.opacity(0.44))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(index == activeIndex ? RoachPalette.green.opacity(0.28) : RoachPalette.border, lineWidth: 1)
                )
            }
        }
    }
}

public struct RoachInfoPill: View {
    private let title: String
    private let value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.green.opacity(0.90),
                                RoachPalette.magenta.opacity(0.52),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 26, height: 3)

                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(0.68),
                                RoachPalette.panelSoft.opacity(0.56),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
            )
    }
}

public struct RoachStatusRow: View {
    private let title: String
    private let value: String
    private let accent: Color

    public init(title: String, value: String, accent: Color) {
        self.title = title
        self.value = value
        self.accent = accent
    }

    public var body: some View {
        HStack {
            HStack(spacing: 10) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(0.34), radius: 8)

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(RoachPalette.muted)
            }

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.18),
                                    accent.opacity(0.07),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
        }
    }
}

public struct RoachDigestRow: View {
    private let label: String
    private let value: String
    private let detail: String
    private let systemName: String
    private let accent: Color
    private let metadata: [String]

    public init(
        _ label: String,
        value: String,
        detail: String,
        systemName: String,
        accent: Color = RoachPalette.green,
        metadata: [String] = []
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.systemName = systemName
        self.accent = accent
        self.metadata = metadata
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.18), accent.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(RoachPalette.muted)

                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)

                if !metadata.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            ForEach(Array(metadata.prefix(3)), id: \.self) { item in
                                roachDigestChip(item)
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(metadata.prefix(3)), id: \.self) { item in
                                roachDigestChip(item)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.54),
                            RoachPalette.panelSoft.opacity(0.40),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
    }

    private func roachDigestChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(accent.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.16), lineWidth: 1)
            )
    }
}

private func roachRuntimeImage(named name: String) -> NSImage? {
    let resourceName = (name as NSString).deletingPathExtension
    let resourceExtension = (name as NSString).pathExtension
    let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks

    for bundle in bundles {
        if let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension.isEmpty ? nil : resourceExtension
        ), let image = NSImage(contentsOf: url) {
            return image
        }

        if let directResource = bundle.resourceURL?.appendingPathComponent(name),
           let image = NSImage(contentsOf: directResource) {
            return image
        }
    }

    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(name),
        Bundle.main.resourceURL?.appendingPathComponent("RoachNetMac_RoachNetApp.bundle/\(name)"),
        Bundle.main.resourceURL?.appendingPathComponent("RoachNetMac_RoachNetSetup.bundle/\(name)"),
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"),
    ].compactMap { $0 }

    for candidate in candidates {
        if let image = NSImage(contentsOf: candidate) {
            return image
        }
    }

    return nil
}

private func roachTemplateImage(from image: NSImage) -> NSImage {
    let template = (image.copy() as? NSImage) ?? image
    template.isTemplate = true
    return template
}

private struct RoachFallbackBrandMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(1.4, size * 0.028)
            let inset = max(2, size * 0.08)

            ZStack {
                Canvas { context, canvasSize in
                    let rect = CGRect(
                        x: (canvasSize.width - size) * 0.5 + inset,
                        y: (canvasSize.height - size) * 0.5 + inset,
                        width: size - inset * 2,
                        height: size - inset * 2
                    )
                    let cut = rect.width * 0.17
                    var shield = Path()
                    shield.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    shield.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY + cut * 0.38))
                    shield.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - cut * 0.18))
                    shield.addLine(to: CGPoint(x: rect.maxX - cut * 0.48, y: rect.maxY - cut * 0.28))
                    shield.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    shield.addLine(to: CGPoint(x: rect.minX + cut * 0.48, y: rect.maxY - cut * 0.28))
                    shield.addLine(to: CGPoint(x: rect.minX, y: rect.midY - cut * 0.18))
                    shield.addLine(to: CGPoint(x: rect.minX + cut, y: rect.minY + cut * 0.38))
                    shield.closeSubpath()

                    let innerRect = rect.insetBy(dx: rect.width * 0.13, dy: rect.height * 0.13)
                    var inner = Path()
                    inner.move(to: CGPoint(x: innerRect.midX, y: innerRect.minY))
                    inner.addLine(to: CGPoint(x: innerRect.maxX - cut * 0.52, y: innerRect.minY + cut * 0.22))
                    inner.addLine(to: CGPoint(x: innerRect.maxX, y: innerRect.midY - cut * 0.1))
                    inner.addLine(to: CGPoint(x: innerRect.maxX - cut * 0.28, y: innerRect.maxY - cut * 0.2))
                    inner.addLine(to: CGPoint(x: innerRect.midX, y: innerRect.maxY))
                    inner.addLine(to: CGPoint(x: innerRect.minX + cut * 0.28, y: innerRect.maxY - cut * 0.2))
                    inner.addLine(to: CGPoint(x: innerRect.minX, y: innerRect.midY - cut * 0.1))
                    inner.addLine(to: CGPoint(x: innerRect.minX + cut * 0.52, y: innerRect.minY + cut * 0.22))
                    inner.closeSubpath()

                    context.stroke(shield, with: .color(RoachPalette.green.opacity(0.86)), lineWidth: lineWidth)
                    context.stroke(inner, with: .color(RoachPalette.text.opacity(0.46)), lineWidth: max(1, lineWidth * 0.72))

                    let railWidth = max(1, size * 0.032)
                    let railHeight = rect.height * 0.56
                    let railY = rect.midY - railHeight * 0.5
                    for offset in [CGFloat(-0.18), CGFloat(0.18)] {
                        let railRect = CGRect(
                            x: rect.midX + rect.width * offset - railWidth * 0.5,
                            y: railY,
                            width: railWidth,
                            height: railHeight
                        )
                        context.fill(
                            Path(roundedRect: railRect, cornerRadius: railWidth),
                            with: .color(RoachPalette.green.opacity(0.58))
                        )
                    }

                    let base = CGRect(
                        x: rect.midX - rect.width * 0.2,
                        y: rect.maxY - rect.height * 0.25,
                        width: rect.width * 0.4,
                        height: max(1, size * 0.024)
                    )
                    context.fill(
                        Path(roundedRect: base, cornerRadius: base.height),
                        with: .color(RoachPalette.magenta.opacity(0.68))
                    )
                }
                .shadow(color: RoachPalette.green.opacity(0.28), radius: size * 0.12, y: size * 0.04)

                Text("RN")
                    .font(.system(size: max(9, size * 0.21), weight: .black, design: .monospaced))
                    .tracking(size * 0.006)
                    .foregroundStyle(RoachPalette.text)
                    .shadow(color: RoachPalette.green.opacity(0.28), radius: size * 0.07)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

public struct RoachModuleMark: View {
    private let systemName: String
    private let assetName: String?
    private let size: CGFloat
    private let isSelected: Bool
    private let glow: Bool

    public init(
        systemName: String,
        assetName: String? = nil,
        size: CGFloat,
        isSelected: Bool = false,
        glow: Bool = false
    ) {
        self.systemName = systemName
        self.assetName = assetName
        self.size = size
        self.isSelected = isSelected
        self.glow = glow
    }

    public var body: some View {
        Group {
            if let assetName, let image = roachRuntimeImage(named: assetName) {
                if glow || isSelected {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .shadow(
                            color: RoachPalette.magenta.opacity(glow ? 0.24 : 0.14),
                            radius: glow ? size * 0.52 : size * 0.18,
                            y: glow ? size * 0.09 : size * 0.04
                        )
                } else {
                    Image(nsImage: roachTemplateImage(from: image))
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .foregroundStyle(RoachPalette.muted)
                }
            } else {
                Image(systemName: systemName)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(isSelected ? RoachPalette.green : RoachPalette.muted)
            }
        }
    }
}

public struct RoachOrbitMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let iconSize = size * 0.90

            ZStack {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 18.0, paused: reduceMotion)) { timeline in
                    Canvas { context, canvasSize in
                        let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                        let cell = max(3.5, size * 0.036)
                        let columns = max(1, Int(ceil(canvasSize.width / cell)))
                        let rows = max(1, Int(ceil(canvasSize.height / cell)))
                        let center = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)

                        for row in 0...rows {
                            for column in 0...columns {
                                let point = CGPoint(x: CGFloat(column) * cell, y: CGFloat(row) * cell)
                                let dx = (point.x - center.x) / max(1, size * 0.48)
                                let dy = (point.y - center.y) / max(1, size * 0.48)
                                let radius = sqrt(dx * dx + dy * dy)
                                let ring = max(0, 1 - abs(Double(radius) - 0.72) * 3.2)
                                let crawl = 0.5 + 0.5 * sin(Double(column + row) * 0.36 + time * 1.3)
                                let threshold = RoachDither.threshold(row: row, column: column) * 0.44
                                let intensity = ring * (0.32 + crawl * 0.26)

                                guard intensity > threshold else { continue }

                                let rect = CGRect(x: point.x, y: point.y, width: max(1, cell - 1.5), height: max(1, cell - 1.5))
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: 1),
                                    with: .color(RoachDither.cellColor(row: row, column: column, accent: RoachPalette.green, intensity: min(0.22, intensity - threshold + 0.04)))
                                )
                            }
                        }
                    }
                    .blendMode(.screen)
                }

                if let iconImage = roachRuntimeImage(named: "RoachNet.icns") {
                    Image(nsImage: iconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: RoachPalette.green.opacity(0.20), radius: size * 0.12, y: size * 0.04)
                } else {
                    RoachFallbackBrandMark()
                        .frame(width: iconSize, height: iconSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RoachNet logo")
    }
}

public struct RoachSectionHeader: View {
    private let kicker: String
    private let title: String
    private let detail: String?

    public init(_ kicker: String, title: String, detail: String? = nil) {
        self.kicker = kicker
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoachKicker(kicker)
            Text(title)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineSpacing(1.1)
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .allowsTightening(true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(2)
            }
        }
    }
}

public struct RoachFeatureTile: View {
    private let label: String
    private let title: String
    private let detail: String
    private let systemName: String
    private let accent: Color
    @State private var hovered = false

    public init(
        _ label: String,
        title: String,
        detail: String,
        systemName: String,
        accent: Color = RoachPalette.green
    ) {
        self.label = label
        self.title = title
        self.detail = detail
        self.systemName = systemName
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(label.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(RoachPalette.muted)

                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)
                }

                Spacer(minLength: 10)

                ZStack {
                    Circle()
                        .fill(accent.opacity(hovered ? 0.20 : 0.14))
                        .frame(width: hovered ? 52 : 46, height: hovered ? 52 : 46)
                        .blur(radius: hovered ? 8 : 5)

                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(accent.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(accent.opacity(hovered ? 0.28 : 0.18), lineWidth: 1)
                        )
                }
            }

            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.92), accent.opacity(0.18)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: hovered ? 104 : 82, height: 3)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent.opacity(hovered ? 0.92 : 0.54))
                    .offset(x: hovered ? 1 : 0, y: hovered ? -1 : 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(hovered ? 0.86 : 0.78),
                                RoachPalette.panel.opacity(hovered ? 0.78 : 0.68),
                                Color.black.opacity(0.18),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(hovered ? 0.16 : 0.10),
                                Color.clear,
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(hovered ? 0.24 : 0.14), lineWidth: 1)
        )
        .overlay(
            RoachAnimatedChrome(cornerRadius: 16, accent: accent)
        )
        .shadow(color: accent.opacity(hovered ? 0.10 : 0.04), radius: hovered ? 24 : 18, x: 0, y: hovered ? 16 : 10)
        .scaleEffect(hovered ? 1.01 : 1.0)
        .offset(y: hovered ? -1 : 0)
        .onHover { inside in
            hovered = inside
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: hovered)
    }
}

public struct RoachInlineField: View {
    private let title: String
    @Binding private var value: String
    private let placeholder: String

    public init(title: String, value: Binding<String>, placeholder: String) {
        self.title = title
        self._value = value
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)

            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.68),
                                    RoachPalette.panelSoft.opacity(0.56),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: 1)
                        .allowsHitTesting(false)
                )
        }
    }
}

public struct RoachTag: View {
    private let text: String
    private let accent: Color

    public init(_ text: String, accent: Color = RoachPalette.green) {
        self.text = text
        self.accent = accent
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.55)
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.12), accent.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            )
    }
}

public struct RoachCommandTray: View {
    private let label: String
    private let prompt: String
    private let keys: String
    @State private var hovered = false

    public init(label: String, prompt: String, keys: String = "⌘K") {
        self.label = label
        self.prompt = prompt
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelGlass,
                                Color.white.opacity(hovered ? 0.05 : 0.03),
                                RoachPalette.green.opacity(hovered ? 0.10 : 0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RoachPalette.green)
            }
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(hovered ? RoachPalette.green.opacity(0.32) : RoachPalette.borderStrong, lineWidth: 1)
            )
            .shadow(color: RoachPalette.green.opacity(hovered ? 0.20 : 0.12), radius: hovered ? 22 : 18, x: 0, y: hovered ? 12 : 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(RoachPalette.muted)
                Text(prompt)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
            }

            Spacer(minLength: 8)

            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(hovered ? RoachPalette.green : RoachPalette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.06), Color.white.opacity(0.025)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: 1)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(0.88),
                                RoachPalette.panel.opacity(0.78),
                                Color.black.opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.green.opacity(0.10),
                                Color.clear,
                                RoachPalette.magenta.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(hovered ? RoachPalette.green.opacity(0.24) : RoachPalette.borderStrong, lineWidth: 1)
        )
        .overlay(
            RoachAnimatedChrome(cornerRadius: 16, accent: RoachPalette.green)
        )
        .shadow(color: RoachPalette.shadow.opacity(hovered ? 0.22 : 0.16), radius: hovered ? 28 : 24, x: 0, y: hovered ? 16 : 12)
        .scaleEffect(hovered ? 1.01 : 1)
        .offset(y: hovered ? -1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: hovered)
    }
}

public struct RoachSidebarTile: View {
    private let title: String
    private let subtitle: String
    private let isSelected: Bool
    private let systemName: String
    private let assetName: String?
    private let isCompact: Bool
    @State private var hovered = false

    public init(
        title: String,
        subtitle: String,
        systemName: String,
        assetName: String? = nil,
        isSelected: Bool,
        isCompact: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemName = systemName
        self.assetName = assetName
        self.isSelected = isSelected
        self.isCompact = isCompact
    }

    public var body: some View {
        Group {
            if isCompact {
                RoachModuleMark(
                    systemName: systemName,
                    assetName: assetName,
                    size: assetName == nil ? 16 : 18,
                    isSelected: isSelected
                )
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isSelected
                                        ? [RoachPalette.panelSoft.opacity(hovered ? 0.84 : 0.72), RoachPalette.panelRaised.opacity(0.68)]
                                        : [RoachPalette.panelRaised.opacity(hovered ? 0.62 : 0.42), RoachPalette.panel.opacity(0.42)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isSelected ? RoachPalette.green.opacity(0.22) : (hovered ? RoachPalette.green.opacity(0.10) : RoachPalette.border.opacity(0.8)),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.12 : 0.06) : .clear, radius: hovered ? 14 : 10, x: 0, y: hovered ? 8 : 6)
            } else {
                HStack(spacing: 12) {
                    RoachModuleMark(
                        systemName: systemName,
                        assetName: assetName,
                        size: assetName == nil ? 15 : 16,
                        isSelected: isSelected
                    )
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            isSelected ? RoachPalette.green.opacity(0.12) : RoachPalette.panelGlass,
                                            Color.white.opacity(0.02),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: isSelected ? RoachPalette.green.opacity(0.16) : .clear, radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? RoachPalette.green.opacity(0.88) : RoachPalette.muted.opacity(hovered ? 0.82 : 0.44))
                        .opacity(isSelected || hovered ? 1 : 0.75)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isSelected
                                    ? [RoachPalette.panelRaised.opacity(0.78), RoachPalette.panel.opacity(0.62)]
                                    : [RoachPalette.panel.opacity(hovered ? 0.34 : 0.12), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.green.opacity(isSelected ? 0.92 : (hovered ? 0.34 : 0.0)),
                                    accentlessSidebarGlow,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2.5, height: isSelected ? 30 : (hovered ? 16 : 0))
                        .padding(.leading, 4)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? RoachPalette.green.opacity(0.14) : Color.white.opacity(hovered ? 0.08 : 0.03), lineWidth: 1)
                )
                .shadow(color: isSelected ? RoachPalette.green.opacity(hovered ? 0.08 : 0.03) : .clear, radius: hovered ? 12 : 8, x: 0, y: hovered ? 6 : 4)
            }
        }
        .scaleEffect(isCompact ? (hovered ? 1.05 : 1.0) : (hovered ? 1.005 : 1.0))
        .offset(y: hovered ? -0.5 : 0)
        .onHover { inside in
            hovered = inside
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: hovered)
    }

    private var accentlessSidebarGlow: Color {
        Color.clear
    }
}

public struct RoachMetricCard: View {
    private let label: String
    private let value: String
    private let detail: String
    @State private var hovered = false

    public init(label: String, value: String, detail: String) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .allowsTightening(false)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(hovered ? 0.74 : 0.64),
                                RoachPalette.panel.opacity(0.54),
                                Color.black.opacity(0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(RoachPalette.magenta.opacity(hovered ? 0.18 : 0.12))
                    .frame(width: 110, height: 110)
                    .blur(radius: 34)
                    .offset(x: hovered ? 108 : 120, y: hovered ? -26 : -20)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [RoachPalette.green.opacity(0.86), RoachPalette.magenta.opacity(0.68)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: hovered ? 42 : 34, height: 3)
                    .padding(.leading, 12)
                    .padding(.top, 10)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(hovered ? RoachPalette.green.opacity(0.16) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: RoachPalette.shadow.opacity(hovered ? 0.14 : 0.10), radius: hovered ? 14 : 12, x: 0, y: hovered ? 10 : 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .help("\(label): \(value)\n\(detail)")
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: hovered)
    }
}

public struct RoachInsetPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.84),
                                    RoachPalette.panel.opacity(0.80),
                                    Color.black.opacity(0.12),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.magenta.opacity(0.07),
                                    Color.clear,
                                    RoachPalette.cyan.opacity(0.025),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.clear, Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            )
            .shadow(color: RoachPalette.shadow.opacity(0.07), radius: 10, x: 0, y: 6)
    }
}

public struct RoachNotice: View {
    private let title: String
    private let detail: String
    private let accent: Color
    private let systemName: String

    public init(title: String, detail: String, accent: Color = RoachPalette.magenta, systemName: String = "exclamationmark.triangle.fill") {
        self.title = title
        self.detail = detail
        self.accent = accent
        self.systemName = systemName
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.16), accent.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [RoachPalette.panelRaised.opacity(0.76), RoachPalette.panel.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        )
        .overlay(
            RoachAnimatedChrome(cornerRadius: 18, accent: accent)
        )
        .shadow(color: RoachPalette.shadow.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}
