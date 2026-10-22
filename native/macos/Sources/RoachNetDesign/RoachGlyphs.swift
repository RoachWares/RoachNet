import SwiftUI

public enum RoachGlyph: String, CaseIterable, Sendable {
    case home
    case suite
    case dev
    case roachClaw
    case org
    case arcade
    case maps
    case education
    case vault
    case runtime

    public var meaning: String {
        switch self {
        case .home: return "A house with a lit window"
        case .suite: return "Four module tiles, one lit"
        case .dev: return "A terminal prompt with a lit cursor"
        case .roachClaw: return "A chat bubble with a lit spark"
        case .org: return "An org chart: a lead and two agents"
        case .arcade: return "A game controller"
        case .maps: return "A folded map with a you-are-here dot"
        case .education: return "A mortarboard with a lit tassel"
        case .vault: return "A vault door with a lit dial"
        case .runtime: return "Two server units, the top one lit"
        }
    }

    public static let grid: CGFloat = 20
    public static let strokeWidth: CGFloat = 1.6

    public var outline: Path {
        Path { p in
            switch self {
            case .home:
                p.move(to: CGPoint(x: 2.75, y: 9.5))
                p.addLine(to: CGPoint(x: 10, y: 3.25))
                p.addLine(to: CGPoint(x: 17.25, y: 9.5))
                p.move(to: CGPoint(x: 4.75, y: 8))
                p.addLine(to: CGPoint(x: 4.75, y: 16.25))
                p.addLine(to: CGPoint(x: 15.25, y: 16.25))
                p.addLine(to: CGPoint(x: 15.25, y: 8))

            case .suite:
                for origin in [
                    CGPoint(x: 3.25, y: 3.25), CGPoint(x: 11.25, y: 3.25), CGPoint(x: 3.25, y: 11.25),
                    CGPoint(x: 11.25, y: 11.25),
                ] {
                    p.addRoundedRect(
                        in: CGRect(origin: origin, size: CGSize(width: 5.5, height: 5.5)),
                        cornerSize: CGSize(width: 1.6, height: 1.6))
                }

            case .dev:
                p.addRoundedRect(
                    in: CGRect(x: 2.5, y: 3.75, width: 15, height: 12.5), cornerSize: CGSize(width: 2.75, height: 2.75))
                p.move(to: CGPoint(x: 5.75, y: 8))
                p.addLine(to: CGPoint(x: 8.5, y: 10.25))
                p.addLine(to: CGPoint(x: 5.75, y: 12.5))

            case .roachClaw:
                p.move(to: CGPoint(x: 6.25, y: 3.25))
                p.addLine(to: CGPoint(x: 13.75, y: 3.25))
                p.addArc(tangent1End: CGPoint(x: 17.25, y: 3.25), tangent2End: CGPoint(x: 17.25, y: 6.75), radius: 3.5)
                p.addLine(to: CGPoint(x: 17.25, y: 10.25))
                p.addArc(
                    tangent1End: CGPoint(x: 17.25, y: 13.75), tangent2End: CGPoint(x: 13.75, y: 13.75), radius: 3.5)
                p.addLine(to: CGPoint(x: 9.25, y: 13.75))
                p.addLine(to: CGPoint(x: 5.25, y: 16.75))
                p.addLine(to: CGPoint(x: 6, y: 13.75))
                p.addArc(tangent1End: CGPoint(x: 2.75, y: 13.75), tangent2End: CGPoint(x: 2.75, y: 10.5), radius: 3.25)
                p.addLine(to: CGPoint(x: 2.75, y: 6.75))
                p.addArc(tangent1End: CGPoint(x: 2.75, y: 3.25), tangent2End: CGPoint(x: 6.25, y: 3.25), radius: 3.5)
                p.closeSubpath()

            case .org:
                p.addEllipse(in: CGRect(x: 7.75, y: 3, width: 4.5, height: 4.5))
                p.addEllipse(in: CGRect(x: 2.5, y: 12.5, width: 4.5, height: 4.5))
                p.addEllipse(in: CGRect(x: 13, y: 12.5, width: 4.5, height: 4.5))
                p.move(to: CGPoint(x: 10, y: 7.5))
                p.addLine(to: CGPoint(x: 10, y: 10.25))
                p.move(to: CGPoint(x: 4.75, y: 12.5))
                p.addLine(to: CGPoint(x: 4.75, y: 10.25))
                p.addLine(to: CGPoint(x: 15.25, y: 10.25))
                p.addLine(to: CGPoint(x: 15.25, y: 12.5))

            case .arcade:
                p.addRoundedRect(
                    in: CGRect(x: 2.25, y: 5.75, width: 15.5, height: 9), cornerSize: CGSize(width: 4.5, height: 4.5))
                p.move(to: CGPoint(x: 6.5, y: 8.6))
                p.addLine(to: CGPoint(x: 6.5, y: 11.9))
                p.move(to: CGPoint(x: 4.85, y: 10.25))
                p.addLine(to: CGPoint(x: 8.15, y: 10.25))

            case .maps:
                p.move(to: CGPoint(x: 2.75, y: 5))
                p.addLine(to: CGPoint(x: 7.25, y: 3.5))
                p.addLine(to: CGPoint(x: 12.75, y: 5))
                p.addLine(to: CGPoint(x: 17.25, y: 3.5))
                p.addLine(to: CGPoint(x: 17.25, y: 15))
                p.addLine(to: CGPoint(x: 12.75, y: 16.5))
                p.addLine(to: CGPoint(x: 7.25, y: 15))
                p.addLine(to: CGPoint(x: 2.75, y: 16.5))
                p.closeSubpath()
                p.move(to: CGPoint(x: 7.25, y: 3.5))
                p.addLine(to: CGPoint(x: 7.25, y: 15))
                p.move(to: CGPoint(x: 12.75, y: 5))
                p.addLine(to: CGPoint(x: 12.75, y: 16.5))

            case .education:
                p.move(to: CGPoint(x: 10, y: 3.75))
                p.addLine(to: CGPoint(x: 17.75, y: 7.5))
                p.addLine(to: CGPoint(x: 10, y: 11.25))
                p.addLine(to: CGPoint(x: 2.25, y: 7.5))
                p.closeSubpath()
                p.move(to: CGPoint(x: 5.5, y: 9.4))
                p.addLine(to: CGPoint(x: 5.5, y: 12.75))
                p.addQuadCurve(to: CGPoint(x: 14.5, y: 12.75), control: CGPoint(x: 10, y: 15.75))
                p.addLine(to: CGPoint(x: 14.5, y: 9.4))
                p.move(to: CGPoint(x: 17.75, y: 7.5))
                p.addLine(to: CGPoint(x: 17.75, y: 11.75))

            case .vault:
                p.addRoundedRect(
                    in: CGRect(x: 2.75, y: 2.75, width: 14.5, height: 14.5), cornerSize: CGSize(width: 3, height: 3))
                p.addEllipse(in: CGRect(x: 5.75, y: 6.5, width: 7, height: 7))
                p.move(to: CGPoint(x: 15, y: 8))
                p.addLine(to: CGPoint(x: 15, y: 12))

            case .runtime:
                p.addRoundedRect(
                    in: CGRect(x: 2.75, y: 3.25, width: 14.5, height: 5.75), cornerSize: CGSize(width: 2, height: 2))
                p.addRoundedRect(
                    in: CGRect(x: 2.75, y: 11, width: 14.5, height: 5.75), cornerSize: CGSize(width: 2, height: 2))
                p.move(to: CGPoint(x: 9, y: 6.125))
                p.addLine(to: CGPoint(x: 14.25, y: 6.125))
                p.move(to: CGPoint(x: 9, y: 13.875))
                p.addLine(to: CGPoint(x: 14.25, y: 13.875))
                p.move(to: CGPoint(x: 5.9, y: 13.875))
                p.addLine(to: CGPoint(x: 5.91, y: 13.875))
            }
        }
    }

    public var lamp: Path {
        Path { p in
            switch self {
            case .home:
                p.addEllipse(in: dot(10, 11.9, 1.6))
            case .suite:
                p.addEllipse(in: dot(14, 14, 1.3))
            case .dev:
                p.addRoundedRect(
                    in: CGRect(x: 10.5, y: 11.1, width: 4, height: 1.9), cornerSize: CGSize(width: 0.95, height: 0.95))
            case .roachClaw:
                let c = CGPoint(x: 10, y: 8.5)
                let r: CGFloat = 3
                let k: CGFloat = 0.7
                p.move(to: CGPoint(x: c.x, y: c.y - r))
                p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
                p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
                p.closeSubpath()
            case .org:
                p.addEllipse(in: dot(10, 5.25, 1.05))
            case .arcade:
                p.addEllipse(in: dot(13.6, 10.25, 1.45))
            case .maps:
                p.addEllipse(in: dot(10, 10, 1.45))
            case .education:
                p.addEllipse(in: dot(17.75, 13.3, 1.3))
            case .vault:
                p.addEllipse(in: dot(9.25, 10, 1.25))
            case .runtime:
                p.addEllipse(in: dot(5.9, 6.125, 1.15))
            }
        }
    }

    private func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }
}

public struct RoachGlyphView: View {
    private let glyph: RoachGlyph
    private let size: CGFloat
    private let isLit: Bool
    private let ink: Color?

    public init(_ glyph: RoachGlyph, size: CGFloat = 18, isLit: Bool = false, ink: Color? = nil) {
        self.glyph = glyph
        self.size = size
        self.isLit = isLit
        self.ink = ink
    }

    public var body: some View {
        let outlineColor = ink ?? (isLit ? RoachPalette.text : RoachPalette.muted)
        let lampColor = isLit ? RoachPalette.signal : outlineColor
        let glow = RoachPalette.signal.opacity(RoachMetrics.glow(0.55))
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / RoachGlyph.grid
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            context.stroke(
                glyph.outline.applying(transform),
                with: .color(outlineColor),
                style: StrokeStyle(lineWidth: RoachGlyph.strokeWidth * scale, lineCap: .round, lineJoin: .round)
            )
            let lamp = glyph.lamp.applying(transform)
            if isLit {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: glow, radius: 2.5 * scale))
                    layer.fill(lamp, with: .color(lampColor))
                }
            } else {
                context.fill(lamp, with: .color(lampColor))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct RoachGlyphTile: View {
    private let glyph: RoachGlyph
    private let isLit: Bool
    private let width: CGFloat
    private let height: CGFloat
    private let glyphSize: CGFloat
    private let ink: Color?

    public init(
        _ glyph: RoachGlyph, isLit: Bool, width: CGFloat = 34, height: CGFloat = 26, glyphSize: CGFloat = 17,
        ink: Color? = nil
    ) {
        self.glyph = glyph
        self.isLit = isLit
        self.width = width
        self.height = height
        self.glyphSize = glyphSize
        self.ink = ink
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(7), style: .continuous)
        RoachGlyphView(glyph, size: glyphSize, isLit: isLit, ink: ink)
            .frame(width: width, height: height)
            .background(shape.fill(RoachPalette.backgroundRaised))
            .overlay(
                shape.strokeBorder(
                    isLit ? RoachPalette.signal.opacity(0.55) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
            )
            .accessibilityHidden(true)
    }
}
