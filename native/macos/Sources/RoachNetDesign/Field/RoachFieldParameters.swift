import Foundation
import simd

public enum RoachFieldParameters {
    public static let slotCount = 52

    enum Slot {
        static let g0 = 0, g1 = 1, g2 = 2, g3 = 3, g4 = 4, g5 = 5, g6 = 6, ripc = 7
        static let dw = 8, df = 9, dl = 10, dq = 11, ds = 12, dp = 13
        static let w0 = 14, w1 = 15, w2 = 16, w3 = 17, w4 = 18, w5 = 19
        static let c0 = 20, c1 = 21, c2 = 22, c3 = 23, c4 = 24
        static let r0 = 25, r1 = 26, r2 = 27, r3 = 28
        static let q0 = 29, q1 = 30, q2 = 31, q3 = 32, q4 = 33
        static let f0 = 34, f1 = 35, f2 = 36, f3 = 37, f4 = 38
        static let l0 = 39, l1 = 40, l2 = 41, l3 = 42
        static let t0 = 43, t1 = 44, t2 = 45, t3 = 46
        static let sw = 47, x0 = 48, x1 = 49, x2 = 50, x3 = 51
    }

    public struct State: Sendable, Equatable {
        public var intensity: Double
        public var motion: Double
        public var pointer: Double
        public var contours: Double
        public var grid: Double
        public var particles: Double
        public var calm: Double

        public static let hero = State(intensity: 1, motion: 1, pointer: 1, contours: 1, grid: 1, particles: 1, calm: 0)
        public static let reading = State(
            intensity: 0.78, motion: 0.55, pointer: 0.5, contours: 0.62, grid: 0.72, particles: 0.7, calm: 0.12)
        public static let quiet = State(
            intensity: 0.5, motion: 0.3, pointer: 0.25, contours: 0.4, grid: 0.5, particles: 0.45, calm: 0.32)
        public static let transition = State(
            intensity: 0.86, motion: 1.7, pointer: 0.35, contours: 1.15, grid: 1, particles: 1.1, calm: 0.05)
    }

    public struct Composition: Sendable, Equatable {
        public var intensity: Double
        public var pointer: Double
        public var motion: Double
        public var gains: [String: Double]

        public init(intensity: Double = 1, pointer: Double = 1, motion: Double = 1, gains: [String: Double] = [:]) {
            self.intensity = intensity
            self.pointer = pointer
            self.motion = motion
            self.gains = gains
        }

        public static let app = Composition(
            intensity: 0.92, pointer: 0.8, motion: 0.85,
            gains: ["weather": 0.9, "contours": 1, "grid": 0.7, "light": 1])
        public static let preview = Composition()
    }

    static let ditherNames = ["bayer4", "bayer8", "blue", "halftone", "scanline"]

    static func ditherWeights(_ spec: RoachJSON?) -> [Double] {
        var weights = [Double](repeating: 0, count: 5)
        guard let spec else { return weights }
        if let name = spec.string {
            if let index = ditherNames.firstIndex(of: name) { weights[index] = 1 }
            return weights
        }
        if let object = spec.object {
            for (key, value) in object {
                if let index = ditherNames.firstIndex(of: key) { weights[index] = value.number ?? 0 }
            }
        }
        return weights
    }

    static func rgb(_ value: String?) -> SIMD3<Float> {
        guard let value, let parsed = RoachRGBA(value) else { return .zero }
        return SIMD3(Float(parsed.red), Float(parsed.green), Float(parsed.blue))
    }

    public static func pack(_ field: RoachJSON?, composition: Composition = .app, state: State = .reading) -> [SIMD4<
        Float
    >] {
        var out = [SIMD4<Float>](repeating: .zero, count: slotCount)
        let f = field ?? .object([:])
        let layers = f["layers"] ?? .object([:])

        func num(_ value: RoachJSON?, _ fallback: Double) -> Double { value?.number ?? fallback }
        func or(_ value: RoachJSON?, _ fallback: Double) -> Double {
            guard let number = value?.number, number != 0 else { return fallback }
            return number
        }
        func pair(_ value: RoachJSON?, _ fallback: (Double, Double)) -> (Double, Double) {
            guard let array = value?.array, array.count >= 2, let a = array[0].number, let b = array[1].number else {
                return fallback
            }
            return (a, b)
        }
        func triple(_ value: RoachJSON?, _ fallback: (Double, Double, Double)) -> (Double, Double, Double) {
            guard let array = value?.array, array.count >= 3, let a = array[0].number, let b = array[1].number,
                let c = array[2].number
            else { return fallback }
            return (a, b, c)
        }
        func set(_ slot: Int, _ a: Double, _ b: Double, _ c: Double, _ d: Double) {
            out[slot] = SIMD4(Float(a), Float(b), Float(c), Float(d))
        }
        func col(_ slot: Int, _ spec: RoachJSON?, _ fallback: (String, Double), alphaScale: Double = 1) {
            var hex = fallback.0
            var alpha = fallback.1
            if let array = spec?.array, let first = array.first?.string {
                hex = first
                alpha = array.count > 1 ? (array[1].number ?? 1) : 1
            } else if let string = spec?.string {
                hex = string
                alpha = 1
            }
            let c = rgb(hex)
            out[slot] = SIMD4(c.x, c.y, c.z, Float(alpha * alphaScale))
        }
        func gain(_ key: String) -> Double { composition.gains[key] ?? 1 }

        let pointer = f["pointer"] ?? .object([:])
        let mode = pointer["mode"] ?? .object([:])
        let ripple = f["ripple"] ?? .object([:])
        let rhythm = f["rhythm"] ?? .object([:])
        let parallax = f["parallax"] ?? .object([:])
        let scrollDepths = triple(parallax["scroll"], (0.08, 0.22, 0.5))
        let tiltDepths = triple(parallax["tilt"], (10, 26, 54))
        let motion = state.motion

        set(
            Slot.g0, num(f["intensity"], 1) * state.intensity * composition.intensity, num(f["alpha"], 0.5),
            num(f["vignette"], 0.3), num(f["trace"], 0.07))
        set(
            Slot.g1, num(f["speed"], 1), or(rhythm["breathPeriod"], 11), num(ripple["strength"], 1) * state.pointer,
            or(ripple["speed"], 640))
        set(Slot.g2, num(mode["illuminate"], 1), num(mode["lens"], 1), or(mode["swirl"], 0), or(pointer["radius"], 236))
        set(
            Slot.g3, num(pointer["strength"], 1) * state.pointer * composition.pointer, or(ripple["width"], 30),
            num(f["streak"], 1), num(f["wind"], 1))
        set(Slot.g4, scrollDepths.0, scrollDepths.1, scrollDepths.2, num(parallax["amount"], 1))
        set(Slot.g5, tiltDepths.0, tiltDepths.1, tiltDepths.2, 0)
        set(
            Slot.g6, or(rhythm["pulse"], 0) * min(1, motion * 1.2), or(rhythm["pulsePeriod"], 7),
            or(rhythm["breath"], 0) * min(1, motion * 1.2), state.calm)
        col(Slot.ripc, ripple["color"], ("#ffffff", 0.6))

        let weather = layers["weather"]
        let fog = layers["fog"]
        let light = layers["light"]
        let particles = layers["particles"]
        let dw = ditherWeights(weather?["dither"] ?? f["dither"] ?? .string("bayer8"))
        let df = ditherWeights(fog?["dither"] ?? f["dither"] ?? .string("blue"))
        let dl = ditherWeights(light?["dither"] ?? f["dither"] ?? .string("bayer8"))
        let dq = ditherWeights(particles?["dither"] ?? .string("blue"))
        set(Slot.dw, dw[0], dw[1], dw[2], dw[3])
        set(Slot.df, df[0], df[1], df[2], df[3])
        set(Slot.dl, dl[0], dl[1], dl[2], dl[3])
        set(Slot.dq, dq[0], dq[1], dq[2], dq[3])
        let lightSmooth: Double = light?["dither"]?.string == "none" ? 1 : 0
        set(Slot.ds, dw[4], df[4], dl[4], lightSmooth)
        let halftone = f["halftone"] ?? .object([:])
        let scanline = f["scanline"] ?? .object([:])
        set(Slot.dp, or(halftone["period"], 5), num(halftone["angle"], 45) * .pi / 180, or(scanline["period"], 3), 0)

        if let w = weather, gain("weather") > 0 {
            let levels = w["levels"]?.array ?? [.array([.string("#9554bb"), .number(0.23)])]
            let range = pair(w["range"], (0.36, 0.84))
            set(
                Slot.w0, num(w["strength"], 0.62) * gain("weather"), or(w["scale"], 540), num(w["warp"], 2.1),
                num(w["speed"], 1))
            set(Slot.w1, range.0, range.1, Double(min(3, levels.count)), num(w["drift"], 0) * .pi / 180)
            col(Slot.w2, levels[0], ("#000000", 0))
            col(Slot.w3, levels.count > 1 ? levels[1] : levels[0], ("#000000", 0))
            col(Slot.w4, levels.count > 2 ? levels[2] : (levels.count > 1 ? levels[1] : levels[0]), ("#000000", 0))
            if let rim = w["rim"]?.array, rim.count >= 2 {
                col(Slot.w5, .array([rim[0], rim[1]]), ("#000000", 0))
            } else {
                col(Slot.w5, nil, ("#000000", 0))
            }
        } else {
            set(Slot.w0, 0, 1, 0, 0)
        }

        let contours = layers["contours"]
        if let c = contours, gain("contours") > 0 {
            let width = pair(c["width"], (2.2, 2.6))
            set(
                Slot.c0, num(c["strength"], 0.92) * gain("contours") * state.contours, or(c["scale"], 400),
                or(c["count"], 12), num(c["speed"], 1))
            set(Slot.c1, or(c["pitch"], 3), or(c["dot"], 2), or(c["majorEvery"], 4), num(c["flow"], 1))
            set(Slot.c2, width.0, width.1, num(c["illuminate"], 1), or(c["glow"], 0))
            col(Slot.c3, c["minor"], ("#b97ede", 0.3))
            col(Slot.c4, c["major"], ("#36ff84", 0.3))
        } else {
            set(Slot.c0, 0, 1, 1, 0)
        }

        let styleIDs: [String: Double] = ["crosses": 0, "lines": 1, "dots": 2, "circuit": 3]
        if let r = layers["grid"], gain("grid") > 0 {
            let style = styleIDs[r["style"]?.string ?? "dots"] ?? 2
            set(Slot.r0, num(r["strength"], 1) * gain("grid") * state.grid, or(r["pitch"], 24), num(r["arm"], 0), style)
            set(Slot.r1, num(r["blink"], 0.14), or(r["wake"], 140), or(r["floor"], 0), num(r["pulse"], 1))
            col(Slot.r2, r["dim"], ("#b97ede", 0.09))
            col(Slot.r3, r["lit"], ("#36ff84", 0.5))
        } else {
            set(Slot.r0, 0, 24, 0, 0)
        }

        let kindIDs: [String: Double] = ["motes": 0, "sparks": 1, "stars": 2]
        if let q = particles, gain("particles") > 0 {
            let colors = q["colors"]?.array ?? []
            set(
                Slot.q0, num(q["strength"], 1) * gain("particles") * state.particles, or(q["cell"], 64),
                num(q["density"], 0.3), kindIDs[q["kind"]?.string ?? "motes"] ?? 0)
            set(Slot.q1, num(q["speed"], 1), num(q["size"], 1.5), num(q["glow"], 6), num(q["twinkle"], 0.3))
            set(Slot.q2, num(q["gather"], 0), num(q["bloom"], 0), num(q["rise"], 0), num(q["wander"], 0))
            col(Slot.q3, colors.first, ("#36ff84", 0.9))
            col(Slot.q4, colors.count > 1 ? colors[1] : colors.first, ("#ffb547", 0.9))
        } else {
            set(Slot.q0, 0, 64, 0, 0)
        }

        if let fg = fog, gain("fog") > 0 {
            let colors = fg["colors"]?.array ?? []
            let range = pair(fg["range"], (0.42, 0.85))
            set(
                Slot.f0, num(fg["strength"], 0.6) * gain("fog"), or(fg["scale"], 620), num(fg["speed"], 1),
                Double(min(3, Int(or(fg["depths"], 3)))))
            set(Slot.f1, range.0, range.1, num(fg["spread"], 0.22), 0)
            col(Slot.f2, colors.first, ("#421a58", 0.4))
            col(Slot.f3, colors.count > 1 ? colors[1] : colors.first, ("#9554bb", 0.3))
            set(Slot.f4, num(fg["nearAlpha"], 1), 0, 0, 0)
        } else {
            set(Slot.f0, 0, 600, 0, 0)
        }

        if let li = light, gain("light") > 0 {
            let at = pair(li["at"], (0.15, 0.05))
            set(Slot.l0, num(li["strength"], 0.5) * gain("light"), at.0, at.1, num(li["radius"], 0.6))
            col(Slot.l1, li["color"], ("#703093", 0.3))
            set(
                Slot.l2, or(li["shafts"], 0), or(li["shaftCount"], 9), num(li["shaftSpeed"], 0.15),
                num(li["bloom"], 0.2))
            col(Slot.l3, li["core"] ?? li["color"], ("#9554bb", 0.4))
        } else {
            set(Slot.l0, 0, 0, 0, 1)
        }

        if let t = layers["terrain"], gain("terrain") > 0 {
            set(
                Slot.t0, num(t["strength"], 1) * gain("terrain"), num(t["horizon"], 0.42), num(t["height"], 0.16),
                num(t["speed"], 0.06))
            set(Slot.t1, or(t["count"], 7), num(t["fog"], 0.18), num(t["width"], 1.6), t["traces"]?.number ?? 0)
            col(Slot.t2, t["color"], ("#5ff2d0", 0.5))
            col(Slot.t3, t["pulse"] ?? t["color"], ("#d1fff4", 0.9))
        } else {
            set(Slot.t0, 0, 0.4, 0.1, 0)
        }

        let lastLevel = weather?["levels"]?.array?.last
        col(Slot.sw, f["sweep"] ?? lastLevel, ("#b97ede", 0.8))
        let tones = pair(weather?["tones"], (0.42, 0.62))
        set(Slot.x0, tones.0, tones.1, 0, 0)
        let roll = rhythm["roll"]
        let rollAmount = roll.map { num($0["amount"], 0.6) } ?? 0
        let rollSpeed = roll.map { or($0["speed"], 0.035) } ?? 0
        set(Slot.x1, rollAmount, rollSpeed, or(contours?["warp"], 0), 0)
        set(Slot.x2, light?["coreAt"]?.number ?? 0.55, or(light?["aspect"], 1), 0, 0)
        let shimmer = contours?["shimmer"]
        set(
            Slot.x3,
            shimmer.map { num($0["amount"], 0.6) } ?? 0,
            shimmer.map { num($0["speed"], 0.5) } ?? 0,
            or(layers["terrain"]?["frequency"], 0),
            or(contours?["mask"], 0)
        )
        return out
    }
}
