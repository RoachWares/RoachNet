import CoreGraphics
import SwiftUI

public struct RoachBrandOperation: Sendable {
    public enum Cap: Sendable { case butt, round, square }
    public enum Join: Sendable { case miter, round, bevel }

    public let fill: String?
    public let stroke: String?
    public let width: CGFloat
    public let cap: Cap
    public let join: Join
    public let evenOdd: Bool
    public let clip: Int
    public let part: String
    public let gait: String
    public let origin: CGPoint?
    public let path: [Float]
}

public struct RoachBrandArt: Sendable {
    public let size: CGSize
    public let clips: [[Float]]
    public let operations: [RoachBrandOperation]

    static func path(_ data: [Float]) -> Path {
        var path = Path()
        var index = 0
        func point() -> CGPoint {
            defer { index += 2 }
            return CGPoint(x: CGFloat(data[index]), y: CGFloat(data[index + 1]))
        }
        while index < data.count {
            let code = Int(data[index])
            index += 1
            switch code {
            case 0: path.move(to: point())
            case 1: path.addLine(to: point())
            case 2:
                let c1 = point()
                let c2 = point()
                let end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
            case 3:
                let control = point()
                let end = point()
                path.addQuadCurve(to: end, control: control)
            default: path.closeSubpath()
            }
        }
        return path
    }
}

public struct RoachMarkPalette: Sendable, Equatable {
    public var ink: Color
    public var pale: Color
    public var wing: Color
    public var wingLight: Color
    public var led: Color

    public static let brand = RoachMarkPalette(
        ink: Color(red: 0x06 / 255, green: 0x06 / 255, blue: 0x0B / 255),
        pale: Color(red: 0xF7 / 255, green: 0xEE / 255, blue: 0xFF / 255),
        wing: Color(red: 0x70 / 255, green: 0x30 / 255, blue: 0x93 / 255),
        wingLight: Color(red: 0x95 / 255, green: 0x54 / 255, blue: 0xBB / 255),
        led: Color(red: 0x36 / 255, green: 0xFF / 255, blue: 0x84 / 255)
    )

    public static func oneColour(_ color: Color) -> RoachMarkPalette {
        RoachMarkPalette(ink: .clear, pale: color, wing: color, wingLight: color, led: color)
    }

    func color(for hex: String) -> Color {
        switch hex.lowercased() {
        case "#06060b": return ink
        case "#f7eeff": return pale
        case "#703093": return wing
        case "#9554bb": return wingLight
        case "#36ff84": return led
        default: return RoachRGBA(hex)?.color ?? pale
        }
    }
}

public struct RoachMark: View {
    public enum Art: Sendable { case roach, wordmark, micromark }
    public enum Activity: Sendable, Equatable { case idle, thinking, listening }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private let art: Art
    private let palette: RoachMarkPalette
    private let animated: Bool
    private let label: String?
    private let activity: Activity
    private let fixedTime: TimeInterval?
    private let fixedScurry: Bool

    public init(
        _ art: Art = .roach, palette: RoachMarkPalette = .brand, animated: Bool = true, label: String? = "RoachNet",
        activity: Activity = .idle
    ) {
        self.art = art
        self.palette = palette
        self.animated = animated
        self.label = label
        self.activity = activity
        self.fixedTime = nil
        self.fixedScurry = false
    }

    public init(
        _ art: Art = .roach, palette: RoachMarkPalette = .brand, label: String? = "RoachNet",
        frameAt time: TimeInterval, scurry: Bool = false, activity: Activity = .idle
    ) {
        self.art = art
        self.palette = palette
        self.animated = false
        self.label = label
        self.activity = activity
        self.fixedTime = time
        self.fixedScurry = scurry
    }

    private var source: RoachBrandArt {
        switch art {
        case .roach: return .rn06
        case .wordmark: return .wordmark
        case .micromark: return .micromark
        }
    }

    public var body: some View {
        let moves = animated && !reduceMotion && art == .roach
        Group {
            if let fixedTime {
                canvas(time: fixedTime, scurrying: fixedScurry)
            } else if moves {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                    canvas(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(time: nil)
            }
        }
        .aspectRatio(source.size.width / source.size.height, contentMode: .fit)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }

    private func canvas(time: TimeInterval?, scurrying: Bool = false) -> some View {
        let source = self.source
        let palette = self.palette
        let scurry = scurrying || hovering || activity == .listening
        let tempo = activity == .thinking ? 2.2 : 1.0
        let ping = activity == .thinking ? 1.2 : 3.6
        return Canvas { context, size in
            let scale = min(size.width / source.size.width, size.height / source.size.height)
            let offset = CGPoint(
                x: (size.width - source.size.width * scale) / 2,
                y: (size.height - source.size.height * scale) / 2
            )
            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: scale, y: scale)
            let headOrigin = source.operations.first { $0.part == "head" }?.origin
            for operation in source.operations {
                var layer = context
                if let time {
                    Self.pose(
                        &layer, operation: operation, time: time, scurry: scurry, headOrigin: headOrigin, tempo: tempo)
                }
                if operation.clip >= 0, operation.clip < source.clips.count {
                    layer.clip(to: RoachBrandArt.path(source.clips[operation.clip]))
                }
                let path = RoachBrandArt.path(operation.path)
                var shade = 1.0
                if let time, operation.part == "led" {
                    let phase = (time.truncatingRemainder(dividingBy: ping)) / ping
                    shade = phase < 0.12 ? 0.55 + 0.45 * sin(phase / 0.12 * .pi) : 0.55 + 0.45
                }
                if let fill = operation.fill {
                    layer.fill(
                        path, with: .color(palette.color(for: fill).opacity(shade)),
                        style: FillStyle(eoFill: operation.evenOdd))
                }
                if let stroke = operation.stroke, operation.width > 0 {
                    layer.stroke(
                        path,
                        with: .color(palette.color(for: stroke)),
                        style: StrokeStyle(
                            lineWidth: operation.width, lineCap: operation.cap.lineCap,
                            lineJoin: operation.join.lineJoin)
                    )
                }
            }
        }
    }

    static func pose(
        _ context: inout GraphicsContext, operation: RoachBrandOperation, time: TimeInterval, scurry: Bool,
        headOrigin: CGPoint?, tempo: Double = 1
    ) {
        func turn(_ degrees: Double, about origin: CGPoint) {
            context.translateBy(x: origin.x, y: origin.y)
            context.rotate(by: .degrees(degrees))
            context.translateBy(x: -origin.x, y: -origin.y)
        }
        let inHead = ["head", "antenna-far", "antenna-near", "led", "eyes"].contains(operation.part)
        if inHead, let headOrigin {
            turn(1.2 * sin(time * 0.9), about: headOrigin)
        }
        guard let origin = operation.origin else { return }
        if operation.part.hasPrefix("antenna") {
            let lead = operation.part == "antenna-far" ? 0.0 : 1.1
            turn((tempo > 1 ? 7 : 5) * sin(time * 1.25 * tempo + lead), about: origin)
        } else if operation.part.hasPrefix("leg"), scurry {
            let side = operation.gait == "a" ? 0.0 : Double.pi
            turn(7 * sin(time * 14 + side), about: origin)
        }
    }
}

extension RoachBrandOperation.Cap {
    var lineCap: CGLineCap {
        switch self {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }
}

extension RoachBrandOperation.Join {
    var lineJoin: CGLineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}
